#!/usr/bin/env ruby

require 'open-uri'
require 'net/http'
require 'uri'
require 'digest/sha1'

class Lucifer
  def initialize(config={})
    @config_file_name = config[:file]

    @cfg = []
    @cfg = File.readlines(@config_file_name) if @config_file_name && File.exists?(@config_file_name)

    @cfg[0] = "#{config[:cycles]}:#{config[:max_cpu]}:#{config[:max_mem]}" if config[:cycles] && config[:max_cpu] && config[:max_mem]
    @cfg[1] = config[:process_string] if config[:process_string]
    @cfg[2] = config[:alert_email] if config[:alert_email]
    @cfg[3] = config[:start_script] if config[:start_script]
    @cfg[4] = config[:restart_email_template] if config[:restart_email_template]
    @cfg[5] = config[:not_running_email_template] if config[:not_running_email_template]
    @cfg[6] = config[:cpu_email_template] if config[:cpu_email_template]
    @cfg[7] = config[:mem_email_template] if config[:mem_email_template]
    @cfg[8] = config[:verify_url] if config[:verify_url]

  end

  def monitor
    @cfg[0]
  end

  def proc_name
    @cfg[1]
  end

  def email_to
    @cfg[2]
  end

  def start_script
    @cfg[3]
  end

  def restart_email_tpl
    @cfg[4]
  end

  def not_running_email_tpl
    @cfg[5]
  end

  def cpu_too_high
    @cfg[6]
  end

  def mem_too_high
    @cfg[7]
  end

  def check_url
    @cfg[8]
  end

  def url_to_check
    chk_url = nil
    chk_url = URI.parse(check_url) if check_url
  end

  def cycles
    mon_split = monitor.split(":")
    return mon_split[0].to_i if mon_split[0]
    10
  end

  def max_cpu
    mon_split = monitor.split(":")
    return mon_split[1].to_i if mon_split[1]
    90
  end

  def max_mem
    mon_split = monitor.split(":")
    return mon_split[2].to_i if mon_split[2]
    90
  end

  def log_name
    proc_name_sha1 = Digest::SHA1.hexdigest(proc_name)
    "#{proc_name_sha1}.log"
  end

  def send_email(who, which, msg, proc_n="")
    email = nil
    File.open(which, 'r') do |file|
      tpl = file.read
      email = tpl.sub(/TO_REPLACE/, who).sub(/MSG_REPLACE/, msg).sub(/PROC_REP/, proc_n)
    end
    stamp = Time.new.to_i.to_s
    temp_email = "#{proc_n||'nil'}-#{stamp}.email"
    File.open(temp_email, 'w') do |eml|
      eml.write(email) if email
    end

    `sendmail #{who.strip} < #{temp_email}`
  end

  def is_server_responding?(chk_url, expected_response_code=200)

    return false unless chk_url
    begin
      http = Net::HTTP.new(chk_url.host, chk_url.port)

      response, data = http.get(chk_url.request_uri)

      return false if expected_response_code != response
    rescue
      return false
    end
    true
  end

  def do_restart(start_script, pid=nil)
    `kill -9 #{pid}` if pid
    `#{start_script}`
  end

  def do_monitor_cycle
    unless File.exists?(log_name) then
      # need to create the file
      system "touch #{log_name}"
    end

    found_proc = false
    matched_proc = nil
    result = `ps -eo %cpu,%mem,pid,cmd`.split("\n")
    result.shift
    result.each do |proc_line|
      proc_data = {}
      sections = proc_line.strip.split(/\s+/)
      cpu = sections.shift
      proc_data[:cpu] = cpu
      mem = sections.shift
      proc_data[:mem] = mem
      pid = sections.shift
      proc_data[:pid] = pid
      cmd = sections.join(" ")
      proc_data[:cmd] = cmd
      if cmd.strip == proc_name.strip then
        matched_proc = proc_data
        puts "MATCHED! WE FOUND THE PROC!"
        found_proc = true
        hist_file = File.readlines(log_name)
        File.open(log_name, 'w') do |file|
          file.puts proc_line
          cycles_minus_one = cycles - 2 # need to actually subtract 2 because of the zero index below
          hist_file[0..cycles_minus_one].each do |line|
            file.puts line
          end
        end
      end
    end


    hist_file = File.readlines(log_name)

# do we have sufficient history to make a judgement?
    if hist_file.size >= cycles then

      cpu_total = 0.0
      mem_total = 0.0
      hist_file.each do |proc_line|
        sections = proc_line.strip.split(/\s+/)
        cpu = sections.shift
        mem = sections.shift

        cpu_total += cpu.to_f
        mem_total += mem.to_f
      end

      cpu_avg = cpu_total / hist_file.size
      mem_avg = mem_total / hist_file.size

      if cpu_avg >= max_cpu.to_f then
        # ALERT!!! CPU IS MAXING OUT!! PANIC PANIC PANIC!!!! -- SEND EMAILS AND RESTART THE PROC
        msg = "CPU IS AVERAGING #{cpu_avg} over #{cycles} cycles"
        send_email(email_to, cpu_too_high, msg, matched_proc[:cmd])
      end

      if mem_avg >= max_mem.to_f then
        # ALERT!!! MEMORY IS MAXING OUT!! PANIC PANIC PANIC!!!! -- SEND EMAILS AND RESTART THE PROC
        msg = "MEM IS AVERAGING #{mem_avg} over #{cycles} cycles"
        send_email(email_to, mem_too_high, msg, matched_proc[:cmd])
      end

      do_restart(start_script, matched_proc ? matched_proc[:pid] : nil ) unless is_server_responding?(url_to_check)
    else
      puts "WAITING FOR ENOUGH INFO... CYCLES: #{cycles} --- LINES: #{hist_file.size}"
    end

    unless found_proc then
      puts "ALERT!!! - PROCESS NOT RUNNING!! --[ #{proc_name} ]"
      # should send emails out
      send_email(email_to, not_running_email_tpl, "THE PROCESS: #{proc_name} is NOT RUNNING!!!")
      # should start the process
      `#{start_script}`
    end
  end
end

if $0 == __FILE__
  config = {
          :file=>"",
          :cycles=>10,
          :max_cpu=>90,
          :max_mem=>90,
          :process_string=>"/usr/local/bin/ruby /usr/local/bin/thin start --threaded --no-epoll -R config.ru -p 15000",
          :alert_email=>"alerts@gmail.com",
          :start_script=>"",
          :restart_email_template=>"",
          :not_running_email_template=>"",
          :cpu_email_template=>"",
          :mem_email_template=>"",
          :verify_url=>""
  }
  devil = Lucifer.new()
end
