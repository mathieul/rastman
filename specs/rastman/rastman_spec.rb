# $Id$

# run with spec -c -f s specs/rastman/rastman_spec.rb

require "spec"
require File.dirname(__FILE__) + "/../mock_tcpsocket.rb"
require File.dirname(__FILE__) + "/../../lib/rastman.rb"

LOGIN_OK = ["user", "valid", {:connect => true}]
LOGIN_NOK = ["user", "not valid", {:connect => true}]
TEST_EVENT = {:event => "UserEvent", :channel => "Local/7002@default-f967,2", :userevent => "SomeEventName"}
LOGIN_OK_1_0 = ["user", "valid", {:connect => true, :version => "1.0"}]

def wait_a_bit
  sleep 0.5
end

describe "The Rastman module" do

  it "should have a default log level set to ERROR and allow to change it" do
    Rastman.log_level.should == Logger::ERROR
    Rastman.log_level = Logger::DEBUG
    Rastman.log_level.should == Logger::DEBUG
    Rastman.log_level = Logger::ERROR
  end
  
  it "should allow to change the logger object" do
    require "stringio"
    Rastman.log_level = Logger::INFO
    io = StringIO.new
    Rastman.set_logger(Logger.new(io))
    io.rewind
    io.read.should match(/Rastman#set_logger: done/)
  end

end

describe "When connecting to Asterisk, a rastman instance" do
  before(:each) do
    MockAsterisk.start
  end

  it "should fail if Asterisk is not running" do
    MockAsterisk.stop
    lambda { asterisk = Rastman::Manager.new(*LOGIN_OK) }.should raise_error(Errno::ECONNREFUSED)
  end

  it "should succeed with valid credentials if Asterisk is running" do
    asterisk = Rastman::Manager.new(*LOGIN_OK)
    asterisk.connected?.should == true
    asterisk.disconnect
  end

  it "should fail with invalid credentials if Asterisk is running" do
    asterisk = nil
    lambda { asterisk = Rastman::Manager.new(*LOGIN_NOK) }.should raise_error(Rastman::LoginError)
  end

end

describe "When connected to Asterisk, a rastman instance" do
  before(:each) do
    MockAsterisk.start
    @asterisk = Rastman::Manager.new(*LOGIN_OK)
  end

  it "should disconnect immediately after disconnectin from Asterisk" do
    @asterisk.disconnect
    wait_a_bit
    @asterisk.connected?.should == false
  end
  
  it "should disconnect after sending a logoff request" do
    @asterisk.logoff
    wait_a_bit; sleep 2
    @asterisk.connected?.should == false
  end
  
  it "should call the event hook if set when asterisk is sending an event" do
    received = []
    @asterisk.add_event_hook(:event) { |evt| received << evt }
    MockAsterisk.send_event(TEST_EVENT)
    wait_a_bit
    received.size.should == 1
    received[0].should == TEST_EVENT
    @asterisk.disconnect
  end
  
  it "should call the action hook if set when asterisk is responding to an action" do
    received = []
    @asterisk.add_event_hook(:action) { |evt| received << evt }
    @asterisk.ping
    wait_a_bit
    received.size.should == 1
    received[0][:response].should == "Pong"
    @asterisk.disconnect
  end
  
  it "should call the disconnection hook if set when the connection is lost" do
    received = []
    @asterisk.add_event_hook(:disconnect) { |evt| received << evt }
    MockAsterisk.stop
    wait_a_bit
    received.size.should == 1
    received[0][:event].should == :disconnect
  end
  
  it "should attempt to reconnect until successfull when the connection is lost" do
    @asterisk.connected?.should == true
    MockAsterisk.stop
    wait_a_bit
    @asterisk.connected?.should == false
    sleep 1
    MockAsterisk.start
    sleep 1
    @asterisk.connected?.should == true
  end
  
  it "should wait until action is answered if action is 'banged' (i.e.: redirect!)" do
    action_id = "some_action_id_here"
    time_for_answer = 2
    action = {
      :response => "Success",
      :message => "Redirect successful",
      :actionid => action_id
    }
    Thread.new { sleep time_for_answer; MockAsterisk.send_event(action) }
    start_time = Time.now
    @asterisk.redirect!(:actionid => action_id).should == true
    time_elapsed = (Time.now - start_time).to_i
    time_elapsed.should == time_for_answer
    @asterisk.disconnect
  end
  
  it "should returned after the requested timeout if 'banged' action is not answered" do
    timeout = 1
    start_time = Time.now
    @asterisk.redirect!(timeout, {}).should == false
    time_elapsed = (Time.now - start_time).to_i
    time_elapsed.should == timeout
    @asterisk.disconnect
  end
  
  it "should have setvar! return true when the command is successful" do
    action = { :response => "Success", :actionid => "123" }
    Thread.new { wait_a_bit; MockAsterisk.send_event(action) }
    @asterisk.getvar!(1, :channel => "SIP/5060-44d225d0",
                         :variable => "hello",
                         :value => "42",
                         :actionid => "123").should be_true
    @asterisk.disconnect
  end
  
  it "should have getvar! return the value when the command is successful" do
    action = { :response => "Success", :actionid => "123", :value => "17065551419" }
    Thread.new { wait_a_bit; MockAsterisk.send_event(action) }
    @asterisk.getvar!(1, :channel => "SIP/5060-44d225d0",
                         :variable => "extension",
                         :actionid => "123").should == "17065551419"
    @asterisk.disconnect
  end
  
  it "should have getvar! return the value when the response is received after another event" do
    action =    { :event => "Newcallerid", :privilege => "call,all",
                  :timestamp => "1213361083.812935", :channel => "SIP/sns-gk1-086cf000",
                  :callerid => "180012345", :calleridname => "<Unknown>",
                  :uniqueid => "1213361083.37",
                  :"cid-callingpres" => "0 (Presentation Allowed, Not Screened)"}
    response =  { :response => "Success", :variable => "ORIGINATE_UNIQUE_ID",
                  :value => "2af9636b4baa326d835d24de8d440XXX",
                  :actionid => "getvar-68564510" }
    Thread.new do
      wait_a_bit; MockAsterisk.send_event(action)
      wait_a_bit; MockAsterisk.send_event(response)
    end
    result = @asterisk.getvar!(1,
                        :channel=>"SIP/sns-gk1-086cf000",
                        :variable=>"ORIGINATE_UNIQUE_ID",
                        :actionid => "getvar-68564510")
    result.should == "2af9636b4baa326d835d24de8d440XXX"
    @asterisk.disconnect
  end
  
  it "should allow to send a command within an event hook" do
    action =    { :event => "Newcallerid", :privilege => "call,all",
                  :timestamp => "1213361083.812935", :channel => "SIP/sns-gk1-086cf000",
                  :callerid => "180012345", :calleridname => "<Unknown>",
                  :uniqueid => "1213361083.37",
                  :"cid-callingpres" => "0 (Presentation Allowed, Not Screened)"}
    response =  { :response => "Success", :variable => "ORIGINATE_UNIQUE_ID",
                  :value => "2af9636b4baa326d835d24de8d440YYY",
                  :actionid => "getvar-68564510" }
    @asterisk.add_event_hook(:event) do |evt|
      Thread.new do
        wait_a_bit; MockAsterisk.send_event(action)
        wait_a_bit; MockAsterisk.send_event(response)
      end
      result = @asterisk.getvar!(1,
                          :channel=> evt[:channel],
                          :variable=>"ORIGINATE_UNIQUE_ID",
                          :actionid => "getvar-68564510")
      result.should == "2af9636b4baa326d835d24de8d440YYY"
    end
    MockAsterisk.send_event(action)
  end
  
  it "should have ping! return true when the command is successful" do
    action = { :response => "Pong", :actionid => "456" }
    Thread.new { wait_a_bit; MockAsterisk.send_event(action) }
    @asterisk.ping!(1, :actionid => "456").should be_true
    @asterisk.disconnect
  end
  
  it "should allow to pass one variable to the originate command" do
    @asterisk.originate(:channel => "SIP/5060-44d225d0", :context => "Main",
      :exten => "recorder", :priority => 1, :timeout => "10000",
      :callerid => "", :variable => "file_name=/path/to/destination",
      :actionid => "789", :async => 1)
    sent = @asterisk.connection.in
    sent.should include("variable: file_name=/path/to/destination")
    @asterisk.disconnect
  end

  it "should allow to pass several variables to the originate command" do
    vars = { "file_name" => "/path/to/file", "format" => "ulaw" }
    @asterisk.originate(:channel => "SIP/5060-44d225d0", :context => "Main",
      :exten => "recorder", :priority => 1, :timeout => "10000",
      :callerid => "", :variable => vars, :actionid => "789",
      :async => 1)
    sent = @asterisk.connection.in
    sent.should include("variable: file_name=/path/to/file")
    sent.should include("variable: format=ulaw")
    @asterisk.disconnect
  end

end

describe "Events generated using the UserEvent command in Asterisk" do
  before(:each) do
    MockAsterisk.start
    @asterisk = Rastman::Manager.new(*LOGIN_OK_1_0)
  end
  
  after(:each) do
    @asterisk.disconnect
  end

  it "should have the same format if they are sent from Asterisk V1.0.x or V1.4.x" do
    evt_1_0 = {
      :event => "UserEventEvtStartScript",
      :variables => "PORT: SIP/10.1.2.98-b78008d8|ANI: lajoo|DNIS: 13002226666"
    }
    evt_1_4 = {
      :event => "UserEvent",
      :userevent => "EvtStartScript",
      :port =>"SIP/10.1.2.98-b78008d8",
      :ani => "lajoo",
      :dnis => "13002226666"
    }
    
    received = []
    @asterisk.add_event_hook(:event) { |evt| received << evt }
    MockAsterisk.send_event(evt_1_0)
    wait_a_bit
    received[0].each_pair { |k,v| v.should == evt_1_4[k] }
  end
  
  it "should set to empty string any empty event variable" do
    evt_1_0 = {
      :event => "UserEventEvtStartScript",
      :variables => "PORT: SIP/10.1.2.98-b78008d8|ANI: lajoo|empty: |DNIS: 13002226666|entry:"
    }
    received = []
    @asterisk.add_event_hook(:event) { |evt| received << evt }
    MockAsterisk.send_event(evt_1_0)
    wait_a_bit
    received[0][:empty].should == ""
    received[0][:entry].should == ""
  end
  
  it "should accept values that contain line returns" do
    multi_lines = "l1\nline 2\nthree"
    event = {
      :event => "UserEventEvtStartScript",
      :variables => "PORT: SIP/10.1.2.98-b78008d8|ANI: lajoo|user_data: #{multi_lines}"
    }
    received = []
    @asterisk.add_event_hook(:event) { |evt| received << evt }
    MockAsterisk.send_event(event)
    wait_a_bit
    received[0][:user_data].should == multi_lines
  end

end

#
#  Created by Mathieul on 2007-02-08.
#  Copyright (c) 2007. All rights reserved.