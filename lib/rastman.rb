# $Id$
# RASTMAN - Ruby Asterisk Manager api
#

require 'monitor'
require 'socket'
require 'timeout'
require 'logger'

$rnlog = Logger.new(STDOUT)
$rnlog.level = Logger::ERROR

# The Rastman module contains the Rastman::Manager class that is used to
# connect to an Asterisk server to send requests and listen to events.
module Rastman

  # Generic Rastman error
  class RastmanError < StandardError; end  
  # Rastman Login error
  class LoginError < RastmanError; end  
  # Rastman Connection error
  class NotConnectedError < RastmanError; end  
  # Rastman Deconnection error
  class DisconnectedError < RastmanError; end  

  LINE_SEPARATOR = "\r\n"

  class << self
    
    # Change the log level (default: Logger::ERROR).
    # Can be set to any of the following:
    # * Logger::DEBUG
    # * Logger::INFO
    # * Logger::WARN
    # * Logger::ERROR
    # * Logger::FATAL
    # * Logger::ANY
    def log_level=(level)
      $rnlog.level = level
    end

    # Return the current log level.
    def log_level
      $rnlog.level
    end

    # Change it for a new one
    def set_logger(new_logger)
      $rnlog = new_logger
      $rnlog.info('Rastman#set_logger: done')
    end

  end
  
  module Parser

    def parse_line(line) # :nodoc:
      raise LocalJumpError, "no block given" unless block_given?
      @buffer ||= ""
      @buffer += line
      # if the line doesn't end with CRLF, we store it for the next call
      if /(^[\w\s\/-]*):[\s]*(.*)\r\n$/m =~ @buffer
        yield($1.downcase.to_sym, $2)
        @buffer = ""
      else
        if @buffer[-2..-1] == "\r\n"
          yield(:unknown, "UNKNOWN")
          @buffer = ""
        end
      end
    end
    
  end

  # A connection with an Asterisk server is established through a
  # Rastman::Manager object. This object can then be used to
  # send Asterisk Manager requests and listens to Asterisk events.
  #
  # Note that events generated from the result of a request won't be sent
  # immediately back by Asterisk on the same connection.
  # So you should probably use one object to send the requests,
  # and one object to listen to the events.
  class Manager
    include Parser

    attr_reader :host, :login

    COMMANDS = [:login, :logoff, :events, :originate, :originate!, :redirect,
      :redirect!, :hangup, :hangup!, :ping, :ping!, :setvar, :setvar!,
      :command, :command!, :getvar!]
    WAIT_FOR_ANSWER = 0.1

    # Returns a Rastman::Manager object. The login and pwd parameters
    # are the username and secret attributes of the user configured
    # in /path/to/asterisk/configuration/manager.conf.
    #
    # The following options are also accepted:
    # * <tt>:port</tt>:               Manager port to connect to (<i>default: 5038</i>),
    # * <tt>:host</tt>:               Host name where Asterisk is running (<i>default: localhost</i>),
    # * <tt>:reconnect_timeout</tt>:  Timeout between two reconnect attempts (<i>default: 1</i>),
    # * <tt>:connect</tt>:            Flag to request a connection right away (<i>default: false</i>).
    # * <tt>:eventmask</tt>:          Manager event mask (i.e.: "user,call") (<i>default: on</i>).
    def initialize(login, pwd, opts = {})
      @login, @pwd = login, pwd
      @port = opts[:port] || 5038
      @host = opts[:host] || 'localhost'
      @version = opts[:version]
      @eventmask = opts[:eventmask] || 'on'
      @reconnect_timeout = opts[:reconnect_timeout] || 1
      @connected, @hooks = false, {}
      @conn_lock = nil
      @conn_lock.extend(MonitorMixin)
      add_event_hook(:reconnect) { event_reconnect }
      connect if opts[:connect]
    end

    # Connects to the server, attempt to login, and start listening to
    # events if successfull.
    #
    # If +should_reconnect+ is true, then the object will attempt to reconnect
    # until successful (the reconnection timeout is configured in new).
    def connect(should_reconnect = true)
      @conn = TCPSocket.new(@host, @port)
      login
      @should_reconnect = should_reconnect
      @listener = Listener.new(@conn, @hooks, :version => @version)
      @listener.start
    end

    # Returns true if the object is currently connected to the server.
    def connected?
      $rnlog.debug("Rastman::Manager#connected?: @connected = #{@connected}")
      @connected == true
    end

    # Disconnects from the server (without sending the _LogOff_ request).
    def disconnect
      raise NotConnectedError, "No active connection" if @conn.closed?
      @should_reconnect = false
      @conn.close
      $rnlog.debug("Rastman::Manager#disconnect: closed connection")
    end
    
    # Returns the connection object.
    def connection
      @conn
    end

    # Adds (or replaces) a block to be executed when the specified event occurs:
    # * <tt>:event</tt>:      an event was received
    # * <tt>:action</tt>:     a response to an action was received
    # * <tt>:reconnect</tt>:  the object got reconnected to the server
    # * <tt>:disconnect</tt>: the object got disconnected from the server
    def add_event_hook(event, &block)
      check_supported_event(event)
      @hooks[event] = block
    end

    # Delete the block that was to be executed for the specified event.
    def del_event_hook(event)
      check_supported_event(event)
      @hooks.delete(event)
    end
    
    def join
      @listener.join
    end

    private
    def check_supported_event(event)
      unless [:event, :action, :disconnect, :reconnect].include?(event)
        raise ArgumentError, "Unsupported event #{event}"
      end
    end
    
    def event_reconnect #:nodoc:
      @connected = false
      $rnlog.debug("Rastman::Manager#event_reconnect: should_reconnect(#{@should_reconnect})")
      @hooks[:disconnect].call({:event => :disconnect}) unless @hooks[:disconnect].nil?
      if @should_reconnect == true
        while @connected == false
          sleep @reconnect_timeout
          connect rescue nil
        end
      end
    end

    def login # :nodoc:
      send_action({ :action => 'login', :username => @login, :secret => @pwd, :events => @eventmask })
      wait_for_login_acknowledgement
    end

    def wait_for_login_acknowledgement # :nodoc:
      Timeout.timeout(10) do
        event, done = {}, false
        until done == true do
          @conn.each(LINE_SEPARATOR) do |line|
            if line == LINE_SEPARATOR
              done = true
              break
            else
              parse_line(line) { |key, value| event[key] = value }
            end
            done = true if @conn.closed?
          end
          if event[:response] == "Success"
            @connected = true
          else
            raise LoginError, event[:message]
          end
          $rnlog.debug("Rastman::Manager#wait_for_login_acknowledgement: @connected(#{@connected}) event(#{event.inspect})")
        end
      end
    rescue Timeout::Error
      raise NotConnectedError, "No answer received for login request"
    end

    # send_action actually send the action requested to Asterisk.
    # If expects_answer_before is NOT set (default), it sends the
    # request and returns nil right away.
    # If expects_answer_before is set, it sends the request, waits
    # for expects_answer_before seconds or until the response is received
    # (whichever comes first) and returns true if the response if received,
    # false if not.
    def send_action(action, expects_answer_before = nil) # :nodoc:
      $rnlog.debug("Rastman::Manager#send_action: SEND '#{action[:action]}' (#{action.inspect})")
      unless expects_answer_before.nil?
        action_id = action[:actionid] ||= "#{action[:action]}-#{action.hash}"
        answer = []
        @listener.request_answer_for(action_id, answer)
      end
      @conn_lock.synchronize do
        action.each do |key, value|
          name = key.to_s
          $rnlog.debug("Rastman::Manager#send_action: write (#{name}: #{value}\\r\\n)")
          case value
          when Hash
            value.each { |k, v| @conn.write("#{name}: #{k.to_s}=#{v}\r\n") }
          else
            @conn.write("#{name}: #{value}\r\n")
          end
        end
        $rnlog.debug("Rastman::Manager#send_action: write (\\r\\n)")
        @conn.write("\r\n")
      end
      result = nil
      unless expects_answer_before.nil?
        waited = 0
        until answer.length > 0
          sleep WAIT_FOR_ANSWER
          waited += WAIT_FOR_ANSWER
          if waited >= expects_answer_before
            answer << {}
          end
        end
        success = case action[:action]
        when "ping" then "Pong"
        else "Success"
        end
        result = answer.first[:response] == success rescue false
        value = answer.first[:value]
      end
      return value || result
    rescue Exception => ex
      $rnlog.warn("Rastman::Manager#send_action: exception caught (connection probably closed already): #{ex}")
    end

    def method_missing(meth, *args, &block) # :nodoc:
      unless COMMANDS.include?(meth)
        raise NoMethodError.new(
        "undefined method `#{meth}' for " +
        "#{self.inspect}:#{self.class.name}"
        )
      end
      command = meth.to_s.downcase
      if command[-1] == ?!
        case args.size
        when 1
          expects_answer_before = 10
          action = args.first
        when 2
          expects_answer_before, action = args
        else
          raise ArgumentError, "#{meth} wrong number of arguments (#{args.size} for 1 or 2)"
        end
        command.chop!
      else
        action = args.size == 0 ? {} : args[0]
        expects_answer_before = nil
      end
      action.merge!({ :action => command })
      @should_reconnect = false if command == "logoff"
      send_action(action, expects_answer_before)
    end

  end

  class Listener  # :nodoc: all
    include Parser

    def initialize(conn, hooks, opts = {})
      @conn, @hooks = conn, hooks
      @action_ids = {}
      @mode_1_0 = opts[:version] == "1.0"
    end

    def start
      @th = Thread.new do
        Thread.current.abort_on_exception = true
        begin
          event = {}
          @conn.each(LINE_SEPARATOR) do |line|
            $rnlog.debug("Rastman::Listener#start: read (#{line.strip})")
            if line == LINE_SEPARATOR
              if event[:event].nil?
                @hooks[:action].call(event.clone) unless @hooks[:action].nil?
                unless event[:actionid].nil?
                  container = @action_ids.delete(event[:actionid])
                  container << event.clone unless container.nil?
                end
              else
                reformat_userevent(event) if @mode_1_0
                @hooks[:event].call(event.clone) unless @hooks[:event].nil?
              end
              event.clear
            else
              parse_line(line) { |key, value| event[key] = value }
            end
          end
        rescue IOError => e
          $rnlog.warn("Rastman::Listener#start: IOError (#{e}) occured => we close the connection")
          @conn.close rescue nil
        end
        $rnlog.info("Rastman::Listener#start: calling reconnect hook before stopping")
        @hooks[:reconnect].call({:event => :reconnect}) unless @hooks[:reconnect].nil?
      end
    end

    def join
      @th.join
    end
    
    def request_answer_for(id, container)
      @action_ids[id] = container
    end
    
    private 
    def reformat_userevent(evt)
      name = evt[:event].split("UserEvent")[1]
      unless name.nil?
        evt[:userevent] = name
        evt[:event] = "UserEvent"
        vars = evt.delete(:variables)
        vars.split("|").each do |pair|
          k, v = pair.split(/: */)
          evt[k.downcase.to_sym] = v || ""
        end unless vars.nil?
        evt.delete(:channel)
      end     
    end

  end

end

#
#  Created by Mathieul on 2007-02-08.
#  Copyright (c) 2007. All rights reserved.