# -*- encoding: utf-8 -*-

# fixes problem with loading on systems with rubyist-aasm installed
gem "state_machine"

require "state_machine"
require "daemons"

module Bluepill
  class Process
    CONFIGURABLE_ATTRIBUTES = [
      :start_command,
      :stop_command,
      :restart_command,

      :stdout,
      :stderr,
      :stdin,

      :daemonize,
      :pid_file,
      :working_dir,
      :environment,

      :start_grace_time,
      :stop_grace_time,
      :restart_grace_time,

      :uid,
      :gid,

      :cache_actual_pid,

      :monitor_children,
      :child_process_factory,

      :pid_command,
      :auto_start,

      :supplementary_groups,

      :stop_signals
    ]

    attr_accessor :name, :watches, :triggers, :logger, :skip_ticks_until, :process_running
    attr_accessor *CONFIGURABLE_ATTRIBUTES
    attr_reader :children, :statistics

    state_machine :initial => :unmonitored do
      # These are the idle states, i.e. only an event (either external or internal) will trigger a transition.
      # The distinction between down and unmonitored is that down
      # means we know it is not running and unmonitored is that we don't care if it's running.
      state :unmonitored, :up, :down

      # These are transitionary states, we expect the process to change state after a certain period of time.
      state :starting, :stopping, :restarting

      event :tick do
        transition all => :up,              :if => :process_running?
        transition all => :down,            :if => :process_stopped_and_monitored?
        transition all => :unmonitored,     :if => :process_stopped_and_unmonitored?
      end
      
      event :started_process do
        transition :starting => :started
      end

      event :start do
        transition [:unmonitored, :down] => :starting
      end

      event :stop do
        transition :up => :stopping
      end

      event :unmonitor do
        transition any => :unmonitored
      end

      event :restart do
        transition [:up, :down] => :restarting
      end

      before_transition any => any, :do => :notify_triggers
      before_transition :stopping => any, :do => :clean_threads

      after_transition any => :starting, :do => :start_process
      after_transition any => :stopping, :do => :stop_process
      after_transition any => :restarting, :do => :restart_process

      after_transition any => any, :do => :record_transition
    end

    def initialize(process_name, checks, options = {})
      @name = process_name
      @event_mutex = Monitor.new
      @watches = []
      @triggers = []
      @children = []
      @threads = []
      @statistics = ProcessStatistics.new
      @actual_pid = options[:actual_pid]
      self.logger = options[:logger]

      checks.each do |name, opts|
        if Trigger[name]
          self.add_trigger(name, opts)
        else
          self.add_watch(name, opts)
        end
      end

      # These defaults are overriden below if it's configured to be something else.
      @monitor_children =  false
      @cache_actual_pid = true
      @start_grace_time = @stop_grace_time = @restart_grace_time = 3
      @environment = {}

      CONFIGURABLE_ATTRIBUTES.each do |attribute_name|
        self.send("#{attribute_name}=", options[attribute_name]) if options.has_key?(attribute_name)
      end

      # Let state_machine do its initialization stuff
      super() # no arguments intentional
    end

    def tick
      return if self.skipping_ticks?
      self.skip_ticks_until = nil

      # clear the memoization per tick
      @process_running = nil

      # Deal with thread cleanup here since the stopping state isn't used
      clean_threads if self.unmonitored?

      # run state machine transitions
      super

      if self.up?
        self.run_watches

        if self.monitor_children?
          refresh_children!
          children.each {|child| child.tick}
        end
      end
    end

    def logger=(logger)
      @logger = logger
      self.watches.each {|w| w.logger = logger }
      self.triggers.each {|t| t.logger = logger }
    end

    # State machine methods
    def dispatch!(event, reason = nil)
      @event_mutex.synchronize do
        @statistics.record_event(event, reason)
        self.send("#{event}")
      end
    end

    def record_transition(transition)
      unless transition.loopback?
        @transitioned = true

        # When a process changes state, we should clear the memory of all the watches
        self.watches.each { |w| w.clear_history! }

        # Also, when a process changes state, we should re-populate its child list
        if self.monitor_children?
          self.logger.warning "Clearing child list"
          self.children.clear
        end
        logger.info "Going from #{transition.from_name} => #{transition.to_name}"
      end
    end

    def notify_triggers(transition)
      self.triggers.each {|trigger| trigger.notify(transition)}
    end

    # Watch related methods
    def add_watch(name, options = {})
      self.watches << ConditionWatch.new(name, options.merge(:logger => self.logger))
    end

    def add_trigger(name, options = {})
      self.triggers << Trigger[name].new(self, options.merge(:logger => self.logger))
    end

    def run_watches
      now = Time.now.to_i

      threads = self.watches.collect do |watch|
        [watch, Thread.new { Thread.current[:events] = watch.run(self.actual_pid, now) }]
      end

      @transitioned = false

      threads.inject([]) do |events, (watch, thread)|
        thread.join
        if thread[:events].size > 0
          logger.info "#{watch.name} dispatched: #{thread[:events].join(',')}"
          thread[:events].each do |event|
            events << [event, watch.to_s]
          end
        end
        events
      end.each do |(event, reason)|
        break if @transitioned
        self.dispatch!(event, reason)
      end
    end

    def determine_initial_state
      if self.process_running?(true)
        self.state = 'up'
      else
        self.state = (auto_start == false) ? 'unmonitored' : 'down' # we need to check for false value
      end
    end

    def handle_user_command(cmd)
      case cmd
      when "start"
        if self.process_running?(true)
          logger.warning("Refusing to re-run start command on an already running process.")
        else
          dispatch!(:start, "user initiated")
        end
      when "stop"
        stop_process
        dispatch!(:unmonitor, "user initiated")
      when "restart"
        restart_process
      when "unmonitor"
        # When the user issues an unmonitor cmd, reset any triggers so that
        # scheduled events gets cleared
        triggers.each {|t| t.reset! }
        dispatch!(:unmonitor, "user initiated")
      end
    end

    # System Process Methods
    def process_running?(force = false)
      @process_running = nil if force # clear existing state if forced

      @process_running ||= signal_process(0)
      # the process isn't running, so we should clear the PID
      self.clear_pid unless @process_running
      @process_running
    end
    
    def process_stopped_and_monitored?
      auto_start and not process_running?
    end
    
    def process_stopped_and_unmonitored?
      not auto_start or process_running?
    end

    def start_process
      logger.warning "Executing start command: #{start_command}"

      if self.daemonize?
        @actual_pid = System.daemonize(start_command, self.system_command_options)
        started_process if @actual_pid
      else
        # This is a self-daemonizing process
        with_timeout(start_grace_time) do
          result = System.execute_blocking(start_command, self.system_command_options)

          unless result[:exit_code].zero?
            logger.warning "Start command execution returned non-zero exit code:"
            logger.warning result.inspect
          end
        end
      end

      self.skip_ticks_for(start_grace_time)
    end

    def stop_process
      if stop_command
        cmd = self.prepare_command(stop_command)
        logger.warning "Executing stop command: #{cmd}"

        with_timeout(stop_grace_time) do
          result = System.execute_blocking(cmd, self.system_command_options)

          unless result[:exit_code].zero?
            logger.warning "Stop command execution returned non-zero exit code:"
            logger.warning result.inspect
          end
        end

      elsif stop_signals
        # issue stop signals with configurable delay between each
        logger.warning "Sending stop signals to #{actual_pid}"
        @threads << Thread.new(self, stop_signals.clone) do |process, stop_signals|
          signal = stop_signals.shift
          logger.info "Sending signal #{signal} to #{process.actual_pid}"
          process.signal_process(signal) # send first signal

          until stop_signals.empty?
            # we already checked to make sure stop_signals had an odd number of items
            delay = stop_signals.shift
            signal = stop_signals.shift

            logger.debug "Sleeping for #{delay} seconds"
            sleep delay
            #break unless signal_process(0) #break unless the process can be reached
            unless process.signal_process(0)
              logger.debug "Process has terminated."
              break
            end
            logger.info "Sending signal #{signal} to #{process.actual_pid}"
            process.signal_process(signal)
          end
        end
      else
        logger.warning "Executing default stop command. Sending TERM signal to #{actual_pid}"
        signal_process("TERM")
      end
      self.unlink_pid # TODO: we only write the pid file if we daemonize, should we only unlink it if we daemonize?

      self.skip_ticks_for(stop_grace_time)
    end

    def restart_process
      if restart_command
        cmd = self.prepare_command(restart_command)

        logger.warning "Executing restart command: #{cmd}"

        with_timeout(restart_grace_time) do
          result = System.execute_blocking(cmd, self.system_command_options)

          unless result[:exit_code].zero?
            logger.warning "Restart command execution returned non-zero exit code:"
            logger.warning result.inspect
          end
        end

        self.skip_ticks_for(restart_grace_time)
      else
        logger.warning "No restart_command specified. Must stop and start to restart"
        self.stop_process
        # the tick will bring it back.
      end
    end

    def clean_threads
      @threads.each { |t| t.kill }
      @threads.clear
    end

    def daemonize?
      !!self.daemonize
    end

    def monitor_children?
      !!self.monitor_children
    end

    def signal_process(code)
      return nil unless actual_pid.present?
      
      code = code.to_s.upcase if code.is_a?(String) || code.is_a?(Symbol)
      ::Process.kill(code, actual_pid)
      true
    rescue Exception => e
      logger.err "Failed to signal process #{actual_pid} with code #{code}: #{e.inspect}"
      
      if e.is_a?(Errno::ESRCH) and pid_file
        File.open(pid_file, 'w') # reset pid file
      end
      
      false
    end

    def cache_actual_pid?
      !!@cache_actual_pid
    end

    def actual_pid
      pid_command ? pid_from_command : pid_from_file
    end

    def pid_from_file
      return @actual_pid if cache_actual_pid? && @actual_pid
      @actual_pid = begin
        if pid_file
          if File.exists?(pid_file)
            str = File.read(pid_file)
            str.to_i if str.size > 0
          else
            logger.warning("pid_file #{pid_file} does not exist or cannot be read")
            nil
          end
        end
      end
    end

    def pid_from_command
      pid = %x{#{pid_command}}.strip
      (pid =~ /\A\d+\z/) ? pid.to_i : nil
    end

    def actual_pid=(pid)
      @actual_pid = pid
    end

    def clear_pid
      @actual_pid = nil
    end

    def unlink_pid
      File.unlink(pid_file) if pid_file && File.exists?(pid_file)
    rescue Errno::ENOENT
    end

     # Internal State Methods
    def skip_ticks_for(seconds)
      # TODO: should this be addative or longest wins?
      #       i.e. if two calls for skip_ticks_for come in for 5 and 10, should it skip for 10 or 15?
      self.skip_ticks_until = (self.skip_ticks_until || Time.now.to_i) + seconds.to_i
    end

    def skipping_ticks?
      self.skip_ticks_until && self.skip_ticks_until > Time.now.to_i
    end

    def refresh_children!
      # First prune the list of dead children
      @children.delete_if {|child| !child.process_running?(true) }

      # Add new found children to the list
      new_children_pids = System.get_children(self.actual_pid) - @children.map {|child| child.actual_pid}

      unless new_children_pids.empty?
        logger.info "Existing children: #{@children.collect{|c| c.actual_pid}.join(",")}. Got new children: #{new_children_pids.inspect} for #{actual_pid}"
      end

      # Construct a new process wrapper for each new found children
      new_children_pids.each do |child_pid|
        name = "<child(pid:#{child_pid})>"
        logger = self.logger.prefix_with(name)

        child = self.child_process_factory.create_child_process(name, child_pid, logger)
        @children << child
      end
    end

    def prepare_command(command)
      command.to_s.gsub("{{PID}}", actual_pid.to_s)
    end

    def system_command_options
      {
        :uid         => self.uid,
        :gid         => self.gid,
        :working_dir => self.working_dir,
        :environment => self.environment,
        :pid_file    => self.pid_file,
        :logger      => self.logger,
        :stdin       => self.stdin,
        :stdout      => self.stdout,
        :stderr      => self.stderr,
        :supplementary_groups => self.supplementary_groups
      }
    end

    def with_timeout(secs, &blk)
      Timeout.timeout(secs.to_f, &blk)

    rescue Timeout::Error
      logger.err "Execution is taking longer than expected. Unmonitoring."
      logger.err "Did you forget to tell bluepill to daemonize this process?"
      self.dispatch!("unmonitor")
    end
  end
end

