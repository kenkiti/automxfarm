#!/usr/bin/env ruby
# 
# mxfarm-carrot-boost
# 
# Copyright (C) 2009 kenkiti
# 

require 'mxfarm'

#Version = "0.0.2"

class MxFarmCarrot < MxFarm
  def land_seed(index)
    @log.info "[land.seed] land_id: %d, crop_type: %s" % [index, 'carrot']
    json = call_api("land.seed", :land_index => index, :crop_type => 'carrot', :naruto => naruto)
    json_data = json["data"]
    @options[:limit] -= 1 if @options[:limit].nil? == false && json_data.has_key?('crop_type')
    json_data.has_key?('crop_type')
  end

  def prepare_seeds
    json = call_api("package.get_merchandise", { :scene_type => 'farm' })
    json_data = json["data"]
    count = (json_data['seeds'].has_key?('carrot')) ? json_data['seeds']['carrot'].to_i : 0
    @log.info "[package.get_merchandise] carrot seeds: %d" % count
    buy_seeds if count == 0 && @options[:limit] > 0
  end

  def buy_seeds(num=99)
    n = (@options[:limit] > num) ? num : @options[:limit]
    store_buy(:scene_type => "farm", :category => "seed", :name => 'carrot', :num => n)
  end

  def is_limit?
    return false if @options[:limit].nil?
    @options[:limit] <= 0 ? true : false
  end

  def boost
    prepare_seeds
    loop do
      json = get_scene("farm")
      farm = json["crops"]["main"]
      return false unless farm.any? {|index, land| land.nil? or land['crop_type'] == 'carrot'}
      farm.each do |index, land|
        if land.nil?
          return false if is_limit?
          prepare_seeds unless land_seed(index)
        elsif land['crop_type'] == 'carrot'
          land_clear(index, land)
        end
      end
    end
  end

  def boost_finished
    json = get_scene("farm")
    farm = json["crops"]["main"]
    farm.each do |index, land|
      next if land.nil?
      land_clear(index, land) if land['crop_type'] == 'carrot'
    end
  end
end

def get_friend_ids(email, password)
  mixi = Mixi.new(email, password)
  mixi.get_session_token(MxFarm::APP_ID)
  friend_ids = mixi.get_viewer_friends.map { |f| f["id"].to_i }
end

def main
  email, password = nil, nil
  verbose = false
  limit = nil
  parser = OptionParser.new
  parser.on("-e", "--email ADDRESS", "email address to login mixi") { |v| email = v }
  parser.on("-p", "--password PASSWORD", "password to login mixi") { |v| password = v }
  parser.on("-l", "--limit NUMBER", "stop after sowing seeds of NUMBER carrot") { |v| limit = v.to_i }
  parser.on("-v", "--verbose", "more info") { |v| verbose = true }
  begin
    parser.parse!(ARGV)
  rescue OptionParser::ParseError => e
    $stderr.puts e.message
    $stderr.puts parser.help
    exit 1
  else
    unless email && password
      puts parser.help
      exit 0
    end
  end
  log_file = nil
  options = {
    :wait => 1.1,
    :verbose => verbose, 
    :limit => limit,
  }
  logger = Logger.new(log_file || STDOUT)
  logger.formatter = LogFormatter.new
  logger.level = verbose ? Logger::DEBUG : Logger::INFO

  while true
    begin 
      friend_ids = get_friend_ids(email, password)
      mixi_app = Mixi.new(email, password)
      mx_carrot = MxFarmCarrot.new(logger, options)
      my_id = mx_carrot.login(mixi_app, friend_ids.compact)
      mx_carrot.get_friends("farm")
      unless mx_carrot.boost
        mx_carrot.boost_finished
        break
      end
    rescue MxFarm::SessionError => e
      logger.warn e.message
      sleep 120
      retry
    end
  end
end

if $0 == __FILE__
  main
end
