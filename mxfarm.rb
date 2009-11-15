#!/usr/bin/env ruby

# mxfarm - automate "sunshine farm"
# 
# Copyright (C) 2009 yakitori
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "kconv"
require "optparse"
require "cgi"
require "uri"
require "time"
require "net/http"
require "singleton"
require "thread"
require "pp"

require "rubygems"
require "mechanize"
require "json"

Version = "0.0.1"
MY_USER_AGENT = "Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10_6_2; ja-jp) AppleWebKit/531.21.8 (KHTML, like Gecko) Version/4.0.4 Safari/531.21.10"

def encode_query(query)
  WWW::Mechanize::Util.build_query_string(query)
end

class Queue
  include Singleton

  def initialize
    @list = []
    @mutex = Mutex.new
  end

  def size
    @list.size
  end

  def push(id)
    @mutex.synchronize do
      case id
      when Array
        @list.concat id
      when Integer, String, NilClass
        @list << id
      else
        raise "Unknown class: %s" % id.class.name
      end
      @list.uniq!
    end
  end

  def pop(num = 1) 
    @mutex.synchronize do
      return @list.slice!(0, num)
    end
  end
end


class Mixi
  attr_reader :my_id, :session_value

  def initialize(email, password)
    @agent = WWW::Mechanize.new { |a|
      a.user_agent = MY_USER_AGENT
      a.follow_meta_refresh = true
    }
    @agent.get "http://mixi.jp/"
    @agent.page.form_with(:name => "login_form") do |f|
      f.field_with(:name => "email").value = email
      f.field_with(:name => "password").value = password
      f.click_button
    end
  end

  def community_size(community_id)
    @agent.get "/view_community.pl", { :id => community_id }
    @agent.page.at("dl.memberNumber>dd").inner_text.to_i
  end

  def community_members(community_id, page_id)
    list = []
    @agent.get "/list_member.pl", { :id => community_id, :page => page_id }
    @agent.page.search("div.iconState01").each do |div|
      if div["id"] =~ /^bg(\d+)$/
        list << $1.to_i
      end
    end
    list
  end

  def get_session_token(app_id)
    @agent.get("/run_appli.pl", :id => app_id)
    @agent.page.iframe_with(:name => "app_content_%d" % app_id).click
    #queries = CGI.parse(@agent.page.uri.query)
    fragments = CGI.parse(@agent.page.uri.fragment)
    @session_token = fragments["st"][0]
  end

  def get_viewer_self
    @agent.get("/social/data/people/@viewer/@self", {
      :fields => "thumbnailUrl,dateOfBirth,gender,hasApp,id,name,thumbnailUrl",
      :startIndex => 0,
      :count => 20,
      :orderBy => "topFriends",
      :filterBy => "all",
      :networkDistance => "",
      :st => @session_token,
    })
    json = JSON.parse(@agent.page.body)
    @my_id = json["id"].to_i
    return json
  end

  def get_viewer_friends
    @agent.get("/social/data/people/@viewer/@friends", {
      :fields => "id,name,thumbnailUrl",
      :startIndex => 0,
      :count => 1000,
      :orderBy => "topFriends",
      :filterBy => "all",
      :networkDistance => "",
      :st => @session_token,
    })
    json = JSON.parse(@agent.page.body)
    json["entry"]
  end

  def make_form(query)
    node = {}
    # Create a fake form
    class << node
      def search(*args)
        []
      end
    end
    node["method"] = "POST"
    node["enctype"] = "application/x-www-form-urlencoded"
    form = WWW::Mechanize::Form.new(node)
    query.each do |k, v|
      form.fields << WWW::Mechanize::Form::Field.new(k.to_s, v)
    end
    form
  end

  def get_session_value(gadget, url, post_data)
    form = make_form({
      "authz" => "signed",
      "bypassSpecCache" => "",
      "container" => "default",
      "contentType" => "JSON",
      "gadget" => gadget,
      "getSummaries" => "false",
      "headers" => encode_query("Content-Type" => "application/x-www-form-urlencoded"),
      "httpMethod" => "POST",
      "numEntries" => "3",
      "postData" => encode_query(post_data),
      "signOwner" => "true",
      "signViewer" => "true",
      "st" => @session_token,
      "url" => url,
    })
    request_uri = URI::HTTP.build({
      :host => @agent.page.uri.host,
      :path => "/gadgets/makeRequest",
    })
    @agent.send(:post_form, request_uri, form, { "X-Mixi-Platform-IO" => "1" })
    dont_be_evil = @agent.page.body
    unless dont_be_evil =~ /\\"session_value\\": \\"(\w+)\\"/
      return nil
    end
    return $1
  end
end


class MxFarm
  GADGET = "http://mxfarm.rekoo.com/?v=%d" % Time.now.to_i
  URL = "http://mxfarm.rekoo.com/embed_swf/"
  APP_ID = 7157

  attr_reader :friend_list

  def initialize
    ## Use net/http instead of mechanize for speeding up
    # @agent = WWW::Mechanize.new { |a| a.user_agent = MY_USER_AGENT }
    @http = Net::HTTP.new("mxfarm.rekoo.com")
  end

  def login(mixi, friend_ids)
    mixi.get_session_token(APP_ID)
    post_data = make_post_data(mixi, friend_ids)
    @session_value = mixi.get_session_value(GADGET, URL, post_data)
    raise unless @session_value
    @my_id = mixi.my_id.to_s
  end

  def make_post_data(mixi, friend_ids)
    viewer_self = mixi.get_viewer_self
    birth_datetime = ""
    if viewer_self["dateOfBirth"]
      birth_datetime = Time.parse(viewer_self["dateOfBirth"]).strftime("%a %b %d %Y %H:%M:%S GMT+0900")
    end
    return {
      :viewer_id => viewer_self["id"],
      :sex => viewer_self["gender"]["key"],
      :name => viewer_self["nickname"],
      :photo => viewer_self["thumbnailUrl"],
      :photo_big => viewer_self["thumbnailUrl"],
      :bdate => birth_datetime,
      :friends => friend_ids.join(","),
    }
  end

  def sec2dhms(sec)
    sec = 0 if sec < 0
    min, sec = sec.divmod(60)
    hour, min = min.divmod(60)
    day, hour = hour.divmod(24)
    str = "%02d:%02d:%02d" % [hour, min, sec]
    if day > 0
      str = "%d day%s, " % [day, day == 1 ? "" : "s"] + str
    end
    str
  end

  def call_api(method, params = {})
    if method =~ /^(?:land|fold)\./
      params[:land_belong] = "main"
    end
    post_data = {
      :sessionid => @session_value,
      :rekoo_killer => @my_id,
      :method => method,
    }.merge(params)
    ## Use net/http instead of mechanize for speeding up
    # @agent.post("http://mxfarm.rekoo.com/get_api/", post_data)
    # json = JSON.parse(@agent.page.body)
    sleep 2
    response = @http.post("/get_api/", encode_query(post_data), {
      "User-Agent" => MY_USER_AGENT,
      "Accept-Language" => "ja",
    })
    json = JSON.parse(response.body)
    json["data"]
  end

  def get_friends(type = "farm")
    json = call_api("user.get_friends", {
      :scene_type => type,
      :uid => @my_id,
      :store => "false",
      :config => "false",
    })
    @friend_list = {}
    json.each do |friend|
      @friend_list[friend["uid"]] = {
        :name => friend["name"],
        :login_time => friend["login_time"].to_i,
        :state => friend["state"].to_i,
      }
    end
    @friend_list
  end

  def get_scene(type, mixi_id = nil)
    json = call_api("user.get_scene", {
      :scene_type => type,
      :uid => mixi_id || @my_id,
      :store => "false",
      :config => "false",
    })
    json[type]
  end

  def get_merchandise(type)
    json = call_api("package.get_merchandise", { :scene_type => type })
    json[type == "farm" ? "seeds" : "babies"].keys.first
  end

  def friend_name(friend_id)
    friend = @friend_list[friend_id]
    name = friend ? friend[:name] : "?"
    "%s(%d)" % [name, friend_id]
  end

  def pesters_name(land)
    return "" if land["pester"].empty?
    list = land["pester"].map { |id| friend_name(id) }
    "[pester: %s]" % list.join(", ")
  end
 
  def scarers_name(fold)
    return "" if fold["scarer"].empty?
    list = fold["scarer"].map { |id| friend_name(id) }
    "[scarer: %s]" % list.join(", ")
  end

  def treat_mine(params = {})
    treat_my_farm(params)
    treat_my_ranch(params)
  end

  def treat_friends(params = {})
    get_friends.each do |friend_id, friend|
      next if friend_id == @my_id
      interval = Time.now.to_i - friend[:login_time]
      if params[:verbose]
        puts "scanning the scene of %s..." % friend_name(friend_id)
        puts "absense time: %s" % sec2dhms(interval)
      end
      next if interval > 60 * 60 * 24 * 5
      treat_friend_farm(friend_id, params)
      treat_friend_ranch(friend_id, params)
    end
  end

  def store_buy(type, params)
    puts "[store.buy] type: %s, name: %s, num: %d" % [params[:type], params[:name], params[:num]]
    call_api("store.buy", {
      :type => params[:type],
      :name => params[:name],
      :num => params[:num],
      :scene_type => type,
      :category => "property",
      :money_type => "gold",
    })
  end

  def land_clear(index, land)
    puts "[land.clear] land_id: %d, crop_type: %s" % [index, land["crop_type"]]
    call_api("land.clear", :land_index => index)
  end

  def land_seed(index, land)
    merchandise_type = get_merchandise("farm")
    return unless merchandise_type
    puts "[land.seed] land_id: %d, crop_type: %s" % [index, merchandise_type]
    call_api("land.seed", :land_index => index, :crop_type => merchandise_type)
  end

  def fold_clear(index, fold)
    puts "[fold.clear] fold_id: %d, animal_type: %s" % [index, fold["animal_type"]]
    call_api("fold.clear", :land_index => index)
  end

  def fold_breed
    merchandise_type = get_merchandise("ranch")
    return unless merchandise_type
    puts "[fold.breed] animal_type: %s" % merchandise_type
    call_api("fold.breed", :type => merchandise_type, :num => 1)
  end
  
  def treat_my_farm(params)
    json = get_scene("farm")
    unless json["task_login"]
      puts "[task.everyday_login]"
      call_api("task.everyday_login")
    end
    farm = json["crops"]["main"]
    farm.each do |index, land|
      next unless land.nil?
      land_seed(index, land)
    end
    farm.each do |index, land|
      next if land.nil?
      land["pest"].times do
        puts "[land.kill_pest] land_id: %d, %s" % [index, pesters_name(land)]
        call_api("land.kill_pest", :land_index => index)
      end
    end
    farm.each do |index, land|
      next if land.nil?
      next unless land["water"] == -1
      puts "[land.water] land_id: %d" % index
      call_api("land.water", :land_index => index)
    end
    farm.each do |index, land|
      next if land.nil?
      case land["state"]
      when "fruit"
        puts "[land.harvest] land_id: %d, crop_type: %s" % [index, land["crop_type"]]
        call_api("land.harvest", :land_index => index)
        next unless land["next_state"] == "dead"
        land_clear(index, land)
        land_seed(index, land)
      when "dead"
        land_clear(index, land)
        land_seed(index, land)
      else
        next if land["fertile"] != 0
        store_buy("farm", :type => "fertilizer", :name => "common", :num => 1)
        puts "[land.fertilize] land_id: %d, name: common" % index
        call_api("land.fertilize", :land_index => index, :name => "common")
      end
    end
  end

  def treat_my_ranch(params)
    json = get_scene("ranch")
    if json["sink"]["state"] == 1
      puts "[fold.water]"
      call_api("fold.water")
    end
    ranch = json["animals"]["main"]
    ranch.each do |index, fold|
      next unless fold.nil?
      fold_breed
    end
    ranch.each do |index, fold|
      next if fold.nil?
      next unless fold["is_scare"]
      puts "[fold.cure] fold_id: %d, %s" % [index, scarers_name(fold)]
      call_api("fold.cure", :land_index => index)
    end
    ranch.each do |index, fold|
      next if fold.nil?
      case fold["state"]
      when "fruit"
        puts "[fold.harvest] fold_id: %d" % index
        call_api("fold.harvest", { :land_index => index })
        next unless fold["next_state"] == "dead"
        fold_clear(index, fold)
        fold_breed
      when "dead"
        fold_clear(index, fold)
        fold_breed
      else
        next if fold["is_feed"] != 0
        store_buy("ranch", :type => "feedstuffs", :name => "common", :num => 1)
        puts "[fold.feed] land_id: %d, name: common" % index
        call_api("fold.feed", :land_index => index, :name => "common")
      end
    end
    ranch.each do |index, fold|
      next if fold.nil?
      total = fold["auto_harvest"].inject(0) { |t, i| t += i }
      if total > 0
         puts "[fold.harvest] fold_id: %d, animal_type: %s" % [index, fold["animal_type"]]
         call_api("fold.harvest", :land_index => index)
      end
    end
  end

  def treat_friend_farm(friend_id, params)
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
    farm.each do |index, land|
      next unless land["state"] == "fruit"
      next if land["total_fruit"].to_i <= 25
      next if land["stealer"].include?(@my_id)
      next if land["caught_stealer"].include?(@my_id)
      puts "[land.friend.steal] mixi: %s, land_id: %d, crop_type: %s" % [friend_name(friend_id), index, land["crop_type"]]
      call_api("land.friend.steal", :land_index => index, :friend_id => friend_id)
    end
  end

  def treat_friend_ranch(friend_id, params)
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
    ranch.each do |index, fold|
      if fold["state"] == "fruit"
         next if fold["total_fruit"].to_i <= 25
         next if fold["stealer"].include?(@my_id)
         next if fold["caught_stealer"].include?(@my_id)
      else
         total = fold["auto_harvest"].inject(0) { |t, i| t += i }
         limit = fold["auto_harvest"].size * 25
         next if total <= limit
         next if fold["stealer"].include?(@my_id)
      end
      puts "[fold.friend.steal] mixi: %s, fold_id: %d, animal_type: %s" % [friend_name(friend_id), index, fold["animal_type"]]
      result = call_api("fold.friend.steal", :land_index => index, :friend_id => friend_id)
    end
  end
end

def main
  email = nil
  password = nil
  community_id = nil
  mixi_ids = nil
  verbose = false
  ARGV.options do |opt|
    opt.on("-e", "--email ADDRESS") { |v| email = v }
    opt.on("-p", "--password PASSWORD") { |v| password = v }
    opt.on("-c", "--community COMMUNITY_ID") { |v| community_id = v.to_i }
    opt.on("-i", "--id MIXI_ID[,MIXI_ID[,...]]") { |v| mixi_ids = v.split(",").map { |x| x.to_i } }
    opt.on("-V", "--verbose") { |v| verbose = true }
    opt.parse!
  end
  return unless email && password
  queue = Queue.instance
  farm_thread = Thread.new(queue) do |q|
    Thread.pass
    puts "[farm_thread] start"
    loop do
      while (friend_ids = q.pop(1000)).empty?
        puts "[farm_thread] sleep"
        sleep 2
      end
      mixi_app = Mixi.new(email, password)
      mx_farm = MxFarm.new
      mx_farm.login(mixi_app, friend_ids.compact)
      friends = mx_farm.get_friends
      mx_farm.treat_mine(:verbose => verbose)
      mx_farm.treat_friends(:verbose => verbose)
      break if friend_ids.last.nil?
    end
    puts "[farm_thread] end"
  end
  mixi = Mixi.new(email, password)
  if community_id
    num = mixi.community_size(community_id)
    pages_list = (1..(num / 50)).to_a.sort_by { |i| rand }
    pages_list.each do |page_id|
      while queue.size > 10000
        sleep 1
      end
      puts "[get_members] page_id: %d, queue_size: %d" % [page_id, queue.size]
      members = mixi.community_members(community_id, page_id)
      queue.push members
      sleep 10
    end
  elsif mixi_ids
    queue.push mixi_ids
  else
    mixi.get_session_token(MxFarm::APP_ID)
    friend_ids = mixi.get_viewer_friends.map { |f| f["id"] }
    queue.push friend_ids
  end
  queue.push nil
  farm_thread.join
end

main
