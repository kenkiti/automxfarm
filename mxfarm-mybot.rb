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

if $0 == __FILE__
  email = nil
  password = nil
  exclude_ids = []
  log_file = nil
  verbose = false
  is_treat_friends = false
  options = {
    :promotant => true,
    :wait => 1.1,
  }
  ARGV.options do |opt|
    opt.on("-e", "--email ADDRESS", "email address to login mixi") { |v| email = v }
    opt.on("-p", "--password PASSWORD", "password to login mixi") { |v| password = v }
    opt.on("-E", "--exclude MIXI_ID[,MIXI_ID[,...]]", "exclude specified ids") { |v| exclude_ids = v.split(",").map { |x| x.to_i } }
    opt.on("-w", "--wait SEC", "wait a time when call API") { |v| options[:wait] = v.to_f }
    #opt.on("-P", "--promotant", "use fertilizer and feedstuffs") { |v| options[:promotant] = true }
    opt.on("-l", "--log FILE", "output info to log file") { |v| log_file = v }
    opt.on("-v", "--verbose", "more info") { |v| verbose = true }

    opt.on("-S", "--steal COUNT", "stop after stealing count times") { |v| options[:steal] = v.to_i }
    opt.on("-C", "--scare COUNT", "stop after scaring count times") { |v| options[:scare] = v.to_i }
    opt.on("-T", "--pest COUNT", "stop after pestering count times") { |v| options[:pest] = v.to_i }
    opt.on("-a", "--all", 'treat all friends') { |v| is_treat_friends = true }
    opt.on('-h', '--help', 'Prints this message and quit') {
      puts parser.help
      exit 0;
    }
    opt.parse!
  end
  return unless email && password
  queue = Queue.instance
  queue.exclude(exclude_ids)
  logger = Logger.new(log_file || STDOUT)
  logger.formatter = LogFormatter.new
  logger.level = verbose ? Logger::DEBUG : Logger::INFO
  farm_thread = Thread.new(queue) do |q|
    Thread.pass
    logger.info "farm_thread: start"
    loop do
      while (friend_ids = q.pop(1000)).empty?
        logger.info "farm_thread: sleep"
        sleep 2
      end
      mixi_app = Mixi.new(email, password)
      mx_farm = MxFarm.new(logger, options)
      mx_farm.login(mixi_app, friend_ids.compact)
      mx_farm.treat_mine
      mx_farm.treat_friends if is_treat_friends
      break if friend_ids.last.nil?
    end
    logger.info "farm_thread: end"
  end

  mixi = Mixi.new(email, password)
  mixi.get_session_token(MxFarm::APP_ID)
  friend_ids = mixi.get_viewer_friends.map { |f| f["id"].to_i }
  queue.push friend_ids
  queue.push nil
  farm_thread.join
end
