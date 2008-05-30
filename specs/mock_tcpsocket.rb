# $Id$

# remove TCPSocket class before we mock it
class Object
  class_eval { remove_const("TCPSocket") }
end

require "stringio"
require "logger"

LOGS = StringIO.new
LOGGER = Logger.new LOGS

class MockAsterisk
  
  class << self

    @@status = :stopped
    @@valid_credentials = ['user', 'valid']
    @@instances = []

    def start
      @@status = :started
    end
    
    def stop
      @@status = :stopped
      @@instances.clone.each { |instance| LOGGER.debug "closing instance [#{instance}]"; instance.close }
    end
    
    def send_event(event)
      @@instances.each do |instance|
        unless instance.out.nil?
          event.each { |k, v| instance.out << "#{k.to_s.capitalize}: #{v}" }
          instance.out << ""
        end
      end
    end

  end
  
  attr_reader :in, :out
  
  def initialize(host, port)
    raise(Errno::ECONNREFUSED, "Connection refused - connect(2)") unless @@status == :started
    @host, @port = host, port
    @out = []
    @in = []
    @event = {}
    LOGGER.debug "adding myself(#{self}) to the list of instances"
    @@instances << self
  end
  
  def closed?
    @closed == true
  end
  
  def write(data)
    raise(IOError, "closed stream") if @closed
    lines = data.scan(/[^\r]*\r\n/)
    @in += lines.collect { |line| line.strip }
    lines.each do |line|
      line = line.downcase
      if line == "\r\n"
        # puts "EVENT type (#{@event[:type].inspect})"
        case @event[:type]
        when :login
          if [@event[:username], @event[:secret]] == @@valid_credentials
            @out = ["Response: Success", "Message: Authentication accepted", ""]
          else
            @out = ["Response: Error", "Message: Authentication failed", ""]
            @closed = true
          end
        when :logoff
          @out = ["Response: Goodbye", "Message: Thanks for all the fish.", ""]
          close
        when :ping
          @out = ["Response: Pong", ""]
        end
        @event.clear
      elsif /^action:(.*)\r\n$/ =~ line
        @event[:type] = $1.strip.to_sym
      else
        @event[$1.downcase.to_sym] = $2 if /(^[\w\s\/-]*):[\s]*(.*)\r\n$/ =~ line
      end
    end
  end
  
  def each(sep = nil)
    raise(IOError, "closed stream") if @out.nil?
    until @out.nil?
      sleep 0.1 while @out.nil? == false && @out.size == 0
      LOGGER.debug "@out (#{@out.inspect})"
      return if @out.nil?
      while @out.size > 0 do
        yield "#{@out.shift}\r\n"
      end if block_given?
    end
  end
  
  def close
    @out = nil
    @closed = true
    @@instances.delete(self)
    LOGGER.debug "closing ...(#{self.inspect})"
  end
  
end

class TCPSocket < MockAsterisk; end

#
#  Created by Mathieul on 2007-02-08.
#  Copyright (c) 2007. All rights reserved.