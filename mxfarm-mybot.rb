# -*- coding: utf-8 -*-
#!/usr/bin/env ruby
#
# mxfarm-mybot - automate "sunshine farm" for me
# 
# Copyright (C) 2009 kenkiti
# 
# サン牧自動手入れ＆無双 使い方
#
# 例1: 自分の畑牧場手入れのみ
# $ ruby automxfarm.rb -e foo@foobar.com -p password
#
# 例2: 自分の畑牧場手入れ ＆ 無双（盗み制限なし、驚かし１人１回まで、虫入れ１人２回まで、無視リスト id(カンマ区切り)）
# $ ruby automxfarm.rb -e foo@foobar.com -p password --steal 0 --scare 1 --pest 2 --all --ignore id
#
# 例3: 自分の畑牧場手入れ ＆ マイミクお手入れ(stealしないで虫入れ驚かし無制限)
# $ ruby automxfarm.rb -e foo@foobar.com -p password --scare 0 --pest 0 --all

require 'mxfarm'
require 'kconv'
require 'base64'
require 'openssl'

#Version = "0.0.1"

class MyBot < MxFarm
  def initialize(logger, options = {})
    super
    @ms = (RUBY_PLATFORM.downcase =~ /mswin(?!ce)|mingw|cygwin|bccwin/) ? true : false
  end

  def friend_name(friend_id)
    friend = @friend_list[friend_id]
    name = friend ? friend[:name] : "?"
    name = "%s(%d)" % [name, friend_id]
    @ms ? name.tosjis : name
  end

  def treat_friends
    friends = get_friends
    friend_ids = friends.keys.sort_by{rand} # shuffle friend ids
    friend_ids.each do |friend_id|
      friend = friends[friend_id]
      next if friend_id == @my_id
      next if @options[:ignore_ids].include?(friend_id.to_i) # ignore id
      interval = Time.now.to_i - friend[:login_time]
      if @options[:verbose]
        puts "scanning the scene of %s..." % friend_name(friend_id)
        puts "absense time: %s" % sec2dhms(interval)
      end
      next if interval > 60 * 60 * 24 * 5
      treat_friend_farm(friend_id)
      treat_friend_ranch(friend_id)
    end
  end

  def treat_friend_farm(friend_id)
    params = Hash[@options]
    json = get_scene("farm", friend_id)
    farm = json["crops"]["main"].delete_if { |k, v| v.nil? }
    farm.each do |index, land|
      next if land["pester"].include?(@my_id)
      land["pest"].times do
        puts "[land.friend.kill_pest] mixi: %s, land_id: %d %s" % [friend_name(friend_id), index, pesters_name(land)]
        call_api("land.friend.kill_pest", :land_index => index, :friend_id => friend_id)
      end
    end
    farm.each do |index, land|
      next unless land["water"] == -1 
      puts "[land.friend.water] mixi: %s, land_id: %d" % [friend_name(friend_id), index]
      call_api("land.friend.water", :land_index => index, :friend_id => friend_id)
    end

    if params[:pest]
      farm.each do |index, land|
        next if land["pester"].include?(@my_id)
        next if land["pest"].to_i >= 3
        next if land["total_fruit"].to_i >= 50 ## Todo
        next if land["state"] == "fruit" || land["state"] == "dead" || land["state"] == "seed"
        puts "[land.friend.put_pest] mixi: %s, land_id: %d," % [friend_name(friend_id), index]
        call_api("land.friend.put_pest", :land_index => index, :friend_id => friend_id)
        break if (params[:pest]-=1) == 0 
      end
    end

    if params[:steal]
      farm.each do |index, land|
        next unless land["state"] == "fruit"
        next if land["total_fruit"].to_i <= 25
        next if land["stealer"].include?(@my_id)
        next if land["caught_stealer"].include?(@my_id)
        puts "[land.friend.steal] mixi: %s, land_id: %d, crop_type: %s" % [friend_name(friend_id), index, land["crop_type"]]
        call_api("land.friend.steal", :land_index => index, :friend_id => friend_id, :naruto => naruto, :type => 'no')
        break if (params[:steal]-=1) == 0 
      end
    end
  end

  def treat_friend_ranch(friend_id)
    params = Hash[@options]
    json = get_scene("ranch", friend_id)
    if json["sink"]["state"] == 1
      puts "[fold.friend.water] mixi: %s" % friend_name(friend_id)
      call_api("fold.friend.water", :friend_id => friend_id)
    end
    ranch = json["animals"]["main"].delete_if { |k, v| v.nil? }
    ranch.each do |index, fold|
      next unless fold["is_scare"]
      next if fold["scarer"].include?(@my_id)
      puts "[fold.friend.cure] mixi: %s, fold_id: %d" % [friend_name(friend_id), index]
      call_api("fold.friend.cure", :land_index => index, :friend_id => friend_id)
    end

    if params[:scare]
      ranch.each do |index, fold|
        next if fold["is_scare"]
        next if fold["scarer"].include?(@my_id)
        next if fold["total_fruit"].to_i >= 50
        next if fold["state"] == "fruit" || fold["state"] == "dead" || fold["state"] == "baby"
        puts "[fold.friend.scare] mixi: %s, fold_id: %d" % [friend_name(friend_id), index]
        call_api("fold.friend.scare", :land_index => index, :friend_id => friend_id)
        break if (params[:scare]-=1) == 0 
      end
    end

    if params[:steal]
      ranch.each do |index, fold|
        if fold["state"] == "fruit"
          next if fold["total_fruit"].to_i <= 50
          next if fold["stealer"].include?(@my_id)
          next if fold["caught_stealer"].include?(@my_id)
        else
          total = fold["auto_harvest"].inject(0) { |t, i| t += i }
          limit = fold["auto_harvest"].size * 25
          next if total <= limit
          next if fold["stealer"].include?(@my_id)
        end
        puts "[fold.friend.steal] mixi: %s, fold_id: %d, animal_type: %s" % [friend_name(friend_id), index, fold["animal_type"]]
        result = call_api("fold.friend.steal", :land_index => index, :friend_id => friend_id, :naruto => naruto, :type => 'no')
        break if (params[:steal]-=1) == 0 
      end
    end
  end

  def encrypt(data)
    password = "waltersh"
    padding = lambda{|s| s.ljust((s.size/8+1)*8, rand(10).to_s)} # adhoc

    c = OpenSSL::Cipher::Cipher.new("des-ecb")
    c.send(:encrypt)
    c.padding = 0 # disable padding
    c.pkcs5_keyivgen(password)
    c.update(padding[data]) + c.final
  end

  def naruto 
    Base64::encode64(encrypt(@my_id))
  end
end

def get_friend_ids(email, password)
  mixi = Mixi.new(email, password)
  mixi.get_session_token(MxFarm::APP_ID)
  friend_ids = mixi.get_viewer_friends.map { |f| f["id"] }
end

def main
  email, password = nil, nil
  verbose = false
  steal, scare, pest = false, false, false
  all = false
  ignore_ids = []
  parser = OptionParser.new
  parser.on("-e", "--email ADDRESS") { |v| email = v }
  parser.on("-p", "--password PASSWORD") { |v| password = v }
  parser.on("-V", "--verbose") { |v| verbose = true }
  parser.on("-S", "--steal N") { |v| steal = v.to_i }
  parser.on("-C", "--scare N") { |v| scare = v.to_i }
  parser.on("-P", "--pest N") { |v| pest = v.to_i }
  parser.on("-I", "--ignore MIXI_ID[,MIXI_ID[,...]]") { |v| ignore_ids = v.split(",").map { |x| x.to_i } }
  parser.on("-a", "--all", 'treat all friends') { |v| all = true }
  parser.on('-h', '--help', 'Prints this message and quit') {
    puts parser.help
    exit 0;
  }
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
  friend_ids = get_friend_ids(email, password)
  mixi_app = Mixi.new(email, password)

  log_file = nil
  options = {
    :wait => 2.0,
    :verbose => verbose, 
    :steal => steal, 
    :pest => pest, 
    :scare => scare, 
    :promotant => true,
    :ignore_ids => ignore_ids
  }
  logger = Logger.new(log_file || STDOUT)
  logger.formatter = LogFormatter.new
  logger.level = verbose ? Logger::DEBUG : Logger::INFO
  mx_farm = MyBot.new(logger, options)
  my_id = mx_farm.login(mixi_app, friend_ids.compact)
  mx_farm.get_friends("farm")
  mx_farm.treat_mine
  mx_farm.treat_friends if all
end

if $0 == __FILE__
  main
end

# TODO:
# 済 friend id を シャッフルする機能
# 済 ignore id 機能
# 済 盗み＆虫入れの回数指定機能
# 済 ニンジンブースト => mxfarm-carrot-boost.rbをつくた
# サブアカ使って交互に虫入れ
