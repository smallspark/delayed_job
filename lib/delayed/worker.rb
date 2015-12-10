require 'timeout'
require 'active_support/core_ext/numeric/time'
require 'active_support/core_ext/class/attribute_accessors'
require 'active_support/core_ext/kernel'
require 'active_support/core_ext/enumerable'
require 'logger'
require 'benchmark'

module Delayed
  class Worker # rubocop:disable ClassLength
    DEFAULT_LOG_LEVEL        = 'info'
    DEFAULT_SLEEP_DELAY      = 5
    DEFAULT_MAX_ATTEMPTS     = 25
    DEFAULT_MAX_RUN_TIME     = 4.hours
    DEFAULT_DEFAULT_PRIORITY = 0
    DEFAULT_DELAY_JOBS       = true
    DEFAULT_QUEUES           = []
    DEFAULT_PRIORITY_QUEUES  = []
    DEFAULT_IGNORE_PRIORITY  = 20.minutes
    DEFAULT_READ_AHEAD       = 5
    DEFAULT_MAX_RESCHEDULE   = 10

    cattr_accessor :min_priority, :max_priority, :max_attempts, :max_run_time,
                   :default_priority, :sleep_delay, :logger, :delay_jobs, :queues, :priority_queues, :ignore_priority,
                   :read_ahead, :plugins, :destroy_failed_jobs, :exit_on_complete, :max_reschedule

    # Named queue into which jobs are enqueued by default
    cattr_accessor :default_queue_name

    cattr_reader :backend

    # Tagged logging
    cattr_accessor :tagged_logger

    # name_prefix is ignored if name is set directly
    attr_accessor :name_prefix

    def self.reset
      self.sleep_delay      = DEFAULT_SLEEP_DELAY
      self.max_attempts     = DEFAULT_MAX_ATTEMPTS
      self.max_run_time     = DEFAULT_MAX_RUN_TIME
      self.default_priority = DEFAULT_DEFAULT_PRIORITY
      self.delay_jobs       = DEFAULT_DELAY_JOBS
      self.queues           = DEFAULT_QUEUES
      self.priority_queues  = DEFAULT_PRIORITY_QUEUES
      self.ignore_priority  = DEFAULT_IGNORE_PRIORITY
      self.read_ahead       = DEFAULT_READ_AHEAD
      self.max_reschedule   = DEFAULT_MAX_RESCHEDULE
    end

    reset

    # Add or remove plugins in this list before the worker is instantiated
    self.plugins = [Delayed::Plugins::ClearLocks]

    # By default failed jobs are destroyed after too many attempts. If you want to keep them around
    # (perhaps to inspect the reason for the failure), set this to false.
    self.destroy_failed_jobs = true

    # By default, Signals INT and TERM set @exit, and the worker exits upon completion of the current job.
    # If you would prefer to raise a SignalException and exit immediately you can use this.
    # Be aware daemons uses TERM to stop and restart
    # false - No exceptions will be raised
    # :term - Will only raise an exception on TERM signals but INT will wait for the current job to finish
    # true - Will raise an exception on TERM and INT
    cattr_accessor :raise_signal_exceptions
    self.raise_signal_exceptions = false

    self.logger = if defined?(Rails)
      Rails.logger
    elsif defined?(RAILS_DEFAULT_LOGGER)
      RAILS_DEFAULT_LOGGER
    end

    def self.backend=(backend)
      if backend.is_a? Symbol
        require "delayed/serialization/#{backend}"
        require "delayed/backend/#{backend}"
        backend = "Delayed::Backend::#{backend.to_s.classify}::Job".constantize
      end
      @@backend = backend # rubocop:disable ClassVars
      silence_warnings { ::Delayed.const_set(:Job, backend) }
    end

    def self.guess_backend
      warn '[DEPRECATION] guess_backend is deprecated. Please remove it from your code.'
    end

    def self.before_fork
      unless @files_to_reopen
        @files_to_reopen = []
        ObjectSpace.each_object(File) do |file|
          @files_to_reopen << file unless file.closed?
        end
      end

      backend.before_fork
    end

    def self.after_fork
      # Re-open file handles
      @files_to_reopen.each do |file|
        begin
          file.reopen file.path, 'a+'
          file.sync = true
        rescue ::Exception # rubocop:disable HandleExceptions, RescueException
        end
      end
      backend.after_fork
    end

    def self.lifecycle
      @lifecycle ||= Delayed::Lifecycle.new
    end

    def initialize(options = {})
      @quiet = options.key?(:quiet) ? options[:quiet] : true
      @failed_reserve_count = 0

      [:min_priority, :max_priority, :sleep_delay, :read_ahead, :queues, :priority_queues, :ignore_priority,
                                                   :max_reschedule, :exit_on_complete].each do |option|
        self.class.send("#{option}=", options[option]) if options.key?(option)
      end

      plugins.each { |klass| klass.new }
    end

    # Every worker has a unique name which by default is the pid of the process. There are some
    # advantages to overriding this with something which survives worker restarts:  Workers can
    # safely resume working on tasks which are locked by themselves. The worker will assume that
    # it crashed before.
    def name
      # Override the logging to simplify it just to the PID
      return Process.pid.to_s

      return @name unless @name.nil?
      "#{@name_prefix}host:#{Socket.gethostname} pid:#{Process.pid}" rescue "#{@name_prefix}pid:#{Process.pid}" # rubocop:disable RescueModifier
    end

    # Sets the name of the worker.
    # Setting the name to nil will reset the default worker name
    attr_writer :name

    def start # rubocop:disable CyclomaticComplexity, PerceivedComplexity
      trap('TERM') do
        say 'Exiting...'
        stop
        fail SignalException.new('TERM') if self.class.raise_signal_exceptions
      end

      trap('INT') do
        say 'Exiting...'
        stop
        fail SignalException.new('INT') if self.class.raise_signal_exceptions && self.class.raise_signal_exceptions != :term
      end

      say 'Starting job worker'

      self.class.lifecycle.run_callbacks(:execute, self) do
        loop do
          self.class.lifecycle.run_callbacks(:loop, self) do
            @realtime = Benchmark.realtime do
              @result = work_off
            end
          end

          count = @result.sum

          if count.zero?
            if self.class.exit_on_complete
              say 'No more jobs available. Exiting'
              break
            elsif !stop?
              sleep(self.class.sleep_delay)
            end
          else
            say format("#{count} jobs processed at %.4f j/s, %d failed", count / @realtime, @result.last)
          end

          break if stop?
        end
      end
    end

    def stop
      @exit = true
    end

    def stop?
      !!@exit
    end

    # Do num jobs and return stats on success/failure.
    # Exit early if interrupted.
    def work_off(num = 100)
      success, failure = 0, 0

      num.times do
        case reserve_and_run_one_job
        when true
          success += 1
        when false
          failure += 1
        else
          break  # leave if no work could be done
        end
        break if stop? # leave if we're exiting
      end

      [success, failure]
    end

    def run(job)

      # Use UUID and tagged logging
      Thread::current[:request_uuid] = job.uuid if job.respond_to?(:uuid) and job.uuid

      tagged_logger.tagged("#{Thread::current[:request_uuid]}") {
        job_say job, 'RUNNING'
        runtime =  Benchmark.realtime do
          Timeout.timeout(self.class.max_run_time.to_i, WorkerTimeout) { job.invoke_job }
          job.destroy
        end
        job_say job, format('COMPLETED after %.4f', runtime)
      }
      Thread::current[:request_uuid] = nil
      return true  # did work
    rescue ResubmitJobError
      Thread::current[:request_uuid] = nil
      job_say job, 'RESUBMITTED'
      return true
    rescue DeserializationError => error
      Thread::current[:request_uuid] = nil
      job.last_error = "#{error.message}\n#{error.backtrace.join("\n")}"
      failed(job)
    rescue => error
      Thread::current[:request_uuid] = nil
      self.class.lifecycle.run_callbacks(:error, self, job) { handle_failed_job(job, error) }
      return false  # work failed
    end

    # Reschedule the job in the future (when a job fails).
    # Uses an exponential scale depending on the number of failed attempts.
    def reschedule(job, time = nil)
      if (job.attempts += 1) < max_attempts(job)
        time ||= job.reschedule_at
        job.run_at = time
        job.unlock
        job.save!
      else
        job_say job, "REMOVED permanently because of #{job.attempts} consecutive failures", 'error'
        failed(job)
      end
    end

    def failed(job)
      self.class.lifecycle.run_callbacks(:failure, self, job) do
        begin
          job.hook(:failure)
        rescue => error
          say "Error when running failure callback: #{error}", 'error'
          say error.backtrace.join("\n"), 'error'
        ensure
          self.class.destroy_failed_jobs ? job.destroy : job.fail!
        end
      end
    end

    def job_say(job, text, level = DEFAULT_LOG_LEVEL)
      text = "Job #{job.name} (id=#{job.id}) #{text}"
      say text, level
    end

    def say(text, level = DEFAULT_LOG_LEVEL)

      text = "(#{name}) #{text}"
      puts text unless @quiet
      return unless logger
      # TODO: Deprecate use of Fixnum log levels
      unless level.is_a?(String)
        level = Logger::Severity.constants.detect { |i| Logger::Severity.const_get(i) == level }.to_s.downcase
      end
      tagged_logger.send(level, text)
    end

    def max_attempts(job)
      job.max_attempts || self.class.max_attempts
    end

  protected

    def handle_failed_job(job, error)
      job.last_error = "#{error.message}\n#{error.backtrace.join("\n")}"
      job_say job, "FAILED (#{job.attempts} prior attempts) with #{error.class.name}: #{error.message}", 'error'
      reschedule(job)
    end

    # Run the next job we can get an exclusive lock on.
    # If no jobs are left we return nil
    def reserve_and_run_one_job
      job = reserve_job
      self.class.lifecycle.run_callbacks(:perform, self, job) { run(job) } if job
    end

    def reserve_job
      job = Delayed::Job.reserve(self)
      @failed_reserve_count = 0
      job
    rescue ::Exception => error # rubocop:disable RescueException
      say "Error while reserving job: #{error}"
      Delayed::Job.recover_from(error)
      @failed_reserve_count += 1
      raise FatalBackendError if @failed_reserve_count >= 10
      nil
    end
  end
end
