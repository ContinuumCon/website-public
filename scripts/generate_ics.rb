#!/usr/bin/env ruby
require 'yaml'
require 'time'
require 'securerandom'
require 'tzinfo'

ROOT = File.expand_path('..', __dir__)
DATA_FILE = File.join(ROOT, '_data', 'schedule.yml')
OUT_FILE = File.join(ROOT, 'assets', 'continuumcon-schedule.ics')

unless File.exist?(DATA_FILE)
  warn "Schedule data not found at #{DATA_FILE}"
  exit 1
end

# Use safe_load with permitted classes to allow YAML dates if present
raw = File.read(DATA_FILE)
data = YAML.safe_load(raw, permitted_classes: [Date], aliases: true)
days = data['days'] || []
stream_links = data['stream_links'] || []
access_url = data['access_conference_url']

# Determine the timezone that session times in schedule.yml should be
# interpreted in. Prefer an explicit `timezone` key in the schedule data,
# then an environment override `CONFERENCE_TZ`. Default to UTC so times
# are treated as global UTC-based values unless you specify otherwise.
conference_tz = (data['timezone'] || ENV['CONFERENCE_TZ'] || 'UTC')

# Auto-fill missing persistent `uid` values with stable random UUIDs so
# subscribers will have stable identifiers. This runs once and writes back
# to `_data/schedule.yml` so values do not change on subsequent runs.
updated = false
days.each do |day|
  (day['sessions'] || []).each do |s|
    next unless s.is_a?(Hash)
    if !s.key?('uid') || s['uid'].to_s.strip == ''
      s['uid'] = SecureRandom.uuid
      updated = true
    end
  end
end
if updated
  File.open(DATA_FILE, 'wb') { |f| f.write(YAML.dump(data)) }
  puts "Updated #{DATA_FILE} with generated session uids"
end

events = []
expected = []
missing_uids = []

days.each do |day|
  raw_date = day['date'] # may be String or Date
  date = raw_date.is_a?(Date) ? raw_date.strftime('%Y-%m-%d') : raw_date.to_s
  sessions = day['sessions'] || []

  sessions.each do |s|
    next unless s['time'] && s['title']
    times = s['time'].to_s.split('-').map(&:strip)
    next unless times.size == 2

    # Interpret the provided times in the configured timezone,
    # convert to UTC and emit Z-terminated UTC timestamps so clients
    # display the event in each viewer's local timezone correctly.
    y, m, d = date.split('-').map(&:to_i)
    sh, sm = times[0].split(':').map(&:to_i)
    eh, em = times[1].split(':').map(&:to_i)
    
    tz = TZInfo::Timezone.get(conference_tz)
    utc_start = tz.local_to_utc(Time.new(y, m, d, sh, sm, 0))
    utc_end = tz.local_to_utc(Time.new(y, m, d, eh, em, 0))
    
    start = utc_start.strftime('%Y%m%dT%H%M%SZ')
    finish = utc_end.strftime('%Y%m%dT%H%M%SZ')

    summary = s['title'].to_s.gsub(/\r?\n/, ' ')
    desc_lines = []
    # Abstract / summary
    desc_lines << s['abstract'].to_s.strip if s['abstract']
    desc_lines << "Level: #{s['difficulty']}" if s['difficulty']

    # Structured streaming section
    if stream_links.any?
      desc_lines << ""
      desc_lines << "Watch the stream:"
      stream_links.each do |sl|
        label = sl['label'] || 'Stream'
        urls = Array(sl['urls'] || sl['url']).compact
        urls.each do |u|
          desc_lines << "- #{u}"
        end
      end
    end

    # Access link section
    if access_url && !access_url.to_s.strip.empty?
      desc_lines << ""
      desc_lines << "Access ContinuumCon content:"
      desc_lines << "- #{access_url}"
    end

    # Join using real newlines then escape newlines for ICS value encoding (\n)
    description = desc_lines.join("\n").gsub(/\r?\n/, "\\n")

    # Require that each session has a persistent `uid` defined in the
    # schedule YAML. Do not auto-generate UIDs here; fail loudly so
    # schedule authors include stable IDs in the source data.
    if s['uid'] && s['uid'].to_s.strip != ''
      uid = "%s@continuumcon.local" % [s['uid'].to_s]
    else
      missing_uids << { date: date, time: times[0], title: summary }
      next
    end

    event = []
    event << "BEGIN:VEVENT"
    event << "UID:#{uid}"
    event << "SUMMARY:#{summary}"
    event << "DTSTART:#{start}"
    event << "DTEND:#{finish}"
    event << "DESCRIPTION:#{description}" unless description.empty?
    event << "END:VEVENT"

    events << event.join("\n")
    expected << { summary: summary, dtstart: start, dtend: finish }
  end
end

ical = []
ical << "BEGIN:VCALENDAR"
ical << "PRODID:-//ContinuumCon//Schedule//EN"
ical << "VERSION:2.0"
ical << "CALSCALE:GREGORIAN"
ical << "X-WR-CALNAME:ContinuumCon Schedule"
ical << "DTSTAMP:#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"

ical << events.join("\r\n\r\n")
ical << "END:VCALENDAR"
File.open(OUT_FILE, 'wb') do |f|
  f.write(ical.join("\r\n") + "\r\n")
end
puts "Wrote #{OUT_FILE} (#{events.size} events)"

# --- validation: parse back generated ICS and ensure events match YAML ---
content = File.read(OUT_FILE)
blocks = content.scan(/BEGIN:VEVENT\n(.*?)\nEND:VEVENT/m).map { |m| m[0] }
errors = []
if blocks.size != expected.size
  errors << "event count mismatch: expected #{expected.size} events, found #{blocks.size} in ICS"
end

blocks.each_with_index do |blk, idx|
  exp = expected[idx]
  next unless exp
  unless blk.include?("SUMMARY:#{exp[:summary]}")
    errors << "event #{idx + 1}: SUMMARY mismatch (expected '#{exp[:summary]}')"
  end
  unless blk.include?(exp[:dtstart].to_s)
    errors << "event #{idx + 1}: DTSTART mismatch (expected #{exp[:dtstart]})"
  end
  unless blk.include?(exp[:dtend].to_s)
    errors << "event #{idx + 1}: DTEND mismatch (expected #{exp[:dtend]})"
  end
end

if errors.any?
  warn "ICS validation failed:\n" + errors.join("\n")
  exit 2
else
  puts "ICS validated: #{blocks.size} events match schedule.yml"
end
if missing_uids.any?
  warn "Missing uid for the following sessions (add a 'uid' field to each session in _data/schedule.yml):"
  missing_uids.each do |m|
    warn "- #{m[:date]} #{m[:time]}: #{m[:title]}"
  end
  exit 3
end
