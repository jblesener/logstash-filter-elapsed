require "logstash/filters/base"
require "logstash/namespace"
require 'thread'
require 'socket'

# The elapsed filter tracks a pair of start/end events and uses their
# timestamps to calculate the elapsed time between them.
#
# The filter has been developed to track the execution time of processes and
# other long tasks.
#
# The configuration looks like this:
# [source,ruby]
#     filter {
#       elapsed {
#         start_tag => "start event tag"
#         end_tag => "end event tag"
#         unique_id_field => "id field name"
#         timeout => seconds
#         new_event_on_match => true/false
#       }
#     }
#
# The events managed by this filter must have some particular properties.
# The event describing the start of the task (the "start event") must contain
# a tag equal to `start_tag`. On the other side, the event describing the end
# of the task (the "end event") must contain a tag equal to `end_tag`. Both
# these two kinds of event need to own an ID field which identify uniquely that
# particular task. The name of this field is stored in `unique_id_field`.
#
# You can use a Grok filter to prepare the events for the elapsed filter.
# An example of configuration can be:
# [source,ruby]
#     filter {
#       grok {
#         match => { "message" => "%{TIMESTAMP_ISO8601} START id: (?<task_id>.*)" }
#         add_tag => [ "taskStarted" ]
#       }
#
#       grok {
#         match => { "message" => "%{TIMESTAMP_ISO8601} END id: (?<task_id>.*)" }
#         add_tag => [ "taskTerminated" ]
#       }
#
#       elapsed {
#         start_tag => "taskStarted"
#         end_tag => "taskTerminated"
#         unique_id_field => "task_id"
#       }
#     }
#
# The elapsed filter collects all the "start events". If two, or more, "start
# events" have the same ID, only the first one is recorded, the others are
# discarded.
#
# When an "end event" matching a previously collected "start event" is
# received, there is a match. The configuration property `new_event_on_match`
# tells where to insert the elapsed information: they can be added to the
# "end event" or a new "match event" can be created. Both events store the
# following information:
#
# * the tags `elapsed` and `elapsed_match`
# * the field `elapsed_time` with the difference, in seconds, between
#   the two events timestamps
# * an ID filed with the task ID
# * the field `elapsed_timestamp_start` with the timestamp of the start event
#
# If the "end event" does not arrive before "timeout" seconds, the
# "start event" is discarded and an "expired event" is generated. This event
# contains:
#
# * the tags `elapsed` and `elapsed_expired_error`
# * a field called `elapsed_time` with the age, in seconds, of the
#   "start event"
# * an ID filed with the task ID
# * the field `elapsed_timestamp_start` with the timestamp of the "start event"
#
# The timestamp field used to calculate elapsed time defaults to @timestamp but
# can be overridden using the timestamp_field config property.
#
class LogStash::Filters::Elapsed < LogStash::Filters::Base
  PREFIX = "elapsed_"
  ELAPSED_FIELD = PREFIX + "time"
  TIMESTAMP_START_EVENT_FIELD = PREFIX + "timestamp_start"
  HOST_FIELD = "host"

  ELAPSED_TAG = "elapsed"
  EXPIRED_ERROR_TAG = PREFIX + "expired_error"
  END_WITHOUT_START_TAG = PREFIX + "end_without_start"
  MATCH_TAG = PREFIX + "match"

  config_name "elapsed"

  # The name of the tag identifying the "start event"
  config :start_tag, :validate => :string, :required => true

  # The name of the tag identifying the "end event"
  config :end_tag, :validate => :string, :required => true

  # The name of the field containing the task ID.
  # This value must uniquely identify the task in the system, otherwise
  # it's impossible to match the couple of events.
  config :unique_id_field, :validate => :string, :required => true

  # The name of the field containing the timestamp.
  # Defaults to "@timestamp"
  config :timestamp_field, :validate => :string, :required => false, :default => "@timestamp"

  # The amount of seconds after an "end event" can be considered lost.
  # The corresponding "start event" is discarded and an "expired event"
  # is generated. The default value is 30 minutes (1800 seconds).
  config :timeout, :validate => :number, :required => false, :default => 1800

  # This property manage what to do when an "end event" matches a "start event".
  # If it's set to `false` (default value), the elapsed information are added
  # to the "end event"; if it's set to `true` a new "match event" is created.
  config :new_event_on_match, :validate => :boolean, :required => false, :default => false

  # This property manage what to do when several "start events" were received
  # before an "end event" for a concrete ID. If it's set to `first` (default
  # value), the first "start event" will be used; if it's set to `last`,
  # the last "start event" will be used.
  config :keep_start_event, :validate => ['first', 'last'], :required => false, :default => 'first'

  # This filter must have its flush function called periodically to be able to purge
  # expired stored start events.
  config :periodic_flush, :validate => :boolean, :default => true

  public
  def register
    @mutex = Mutex.new
    # This is the state of the filter. The keys are the "unique_id_field",
    # the values are couples of values: <start event, age>
    @start_events = {}

    @logger.info("Elapsed, timeout: #{@timeout} seconds")
  end

  # Getter method used for the tests
  def start_events
    @start_events
  end

  def filter(event)


    unique_id = event.get(@unique_id_field)
    return if unique_id.nil?

    if(start_event?(event))
      filter_matched(event)
      @logger.debug("Elapsed, 'start event' received", start_tag: @start_tag, unique_id_field: @unique_id_field)

      @mutex.synchronize do
        unless(@keep_start_event == 'first' && @start_events.has_key?(unique_id))
          @start_events[unique_id] = LogStash::Filters::Elapsed::Element.new(event)
        end
      end

    elsif(end_event?(event))
      filter_matched(event)
      @logger.debug("Elapsed, 'end event' received", end_tag: @end_tag, unique_id_field: @unique_id_field)

      @mutex.lock
      if(@start_events.has_key?(unique_id))
        start_event = @start_events.delete(unique_id).event
        @mutex.unlock
        elapsed = event.get(timestamp_field) - start_event.get(timestamp_field)
        if(@new_event_on_match)
          elapsed_event = new_elapsed_event(elapsed, unique_id, start_event.get(timestamp_field))
          filter_matched(elapsed_event)
          yield elapsed_event if block_given?
        else
          return add_elapsed_info(event, elapsed, unique_id, start_event.get(timestamp_field))
        end
      else
        @mutex.unlock
        # The "start event" did not arrive.
        event.tag(END_WITHOUT_START_TAG)
      end
    end
  end # def filter

  # The method is invoked by LogStash every 5 seconds.
  def flush(options = {})
    expired_elements = []

    @mutex.synchronize do
      increment_age_by(5)
      expired_elements = remove_expired_elements()
    end

    return create_expired_events_from(expired_elements)
  end

  private
  def increment_age_by(seconds)
    @start_events.each_pair do |key, element|
      element.age += seconds
    end
  end

  # Remove the expired "start events" from the internal
  # buffer and return them.
  def remove_expired_elements()
    expired = []
    @start_events.delete_if do |key, element|
      if(element.age >= @timeout)
        expired << element
        next true
      end
      next false
    end

    return expired
  end

  def create_expired_events_from(expired_elements)
    events = []
    expired_elements.each do |element|
      error_event = LogStash::Event.new
      error_event.tag(ELAPSED_TAG)
      error_event.tag(EXPIRED_ERROR_TAG)

      error_event.set(HOST_FIELD, Socket.gethostname)
      error_event.set(@unique_id_field, element.event.get(@unique_id_field) )
      error_event.set(ELAPSED_FIELD, element.age)
      error_event.set(TIMESTAMP_START_EVENT_FIELD, element.event.get(timestamp_field) )

      events << error_event
      filter_matched(error_event)
    end

    return events
  end

  def start_event?(event)
    return (event.get("tags") != nil && event.get("tags").include?(@start_tag))
  end

  def end_event?(event)
    return (event.get("tags") != nil && event.get("tags").include?(@end_tag))
  end

  def new_elapsed_event(elapsed_time, unique_id, timestamp_start_event)
      new_event = LogStash::Event.new
      new_event.set(HOST_FIELD, Socket.gethostname)
      return add_elapsed_info(new_event, elapsed_time, unique_id, timestamp_start_event)
  end

  def add_elapsed_info(event, elapsed_time, unique_id, timestamp_start_event)
      event.tag(ELAPSED_TAG)
      event.tag(MATCH_TAG)

      event.set(ELAPSED_FIELD, elapsed_time)
      event.set(@unique_id_field, unique_id)
      event.set(TIMESTAMP_START_EVENT_FIELD, timestamp_start_event)

      return event
  end
end # class LogStash::Filters::Elapsed

class LogStash::Filters::Elapsed::Element
  attr_accessor :event, :age

  def initialize(event)
    @event = event
    @age = 0
  end
end
