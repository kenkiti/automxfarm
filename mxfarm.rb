#!/usr/bin/env ruby
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
      a.user_agent_alias = "Linux Mozilla"
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
    @agent.get "/run_appli.pl", { :id => app_id }
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
      "headers" => encode_query({ "Content-Type" => "application/x-www-form-urlencoded" }),
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
    @agent = WWW::Mechanize.new { |a|
      a.user_agent_alias = "Mac Safari"
    }
    @http = Net::HTTP.new("mxfarm.rekoo.com")
  end

  def login(mixi, friend_ids)
    mixi.get_session_token(APP_ID)
    post_data = make_post_data(mixi, friend_ids)
    @session_value = mixi.get_session_value(GADGET, URL, post_data)
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

  def call_api(method, params = {})
    if method =~ /^(?:land|fold)\./
      params[:land_belong] = "main"
    end
    post_data = {
      :sessionid => @session_value,
      :rekoo_killer => @my_id,
      :method => method,
    }.merge(params)
    # Use net/http instead of mechanize for speeding up
    #@agent.post("http://mxfarm.rekoo.com/get_api/", post_data)
    #json = JSON.parse(@agent.page.body)
    response = @http.post("/get_api/", encode_query(post_data), {
      "User-Agent" => WWW::Mechanize::AGENT_ALIASES["Linux Mozilla"],
      "Accept-Language" => "ja",
    })
    json = JSON.parse(response.body)
    #sleep 0.1
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
      }
    end
    @friend_list
  end

  def treat_friends
    get_friends.each do |friend_id, friend|
      next if friend_id == @my_id
      next if friend[:login_time] < Time.now.to_i - 60 * 60 * 24 * 5
      next if friend[:login_time] > Time.now.to_i - 60 * 60 * 24 * 1
      treat_friend_farm(friend_id)
      treat_friend_ranch(friend_id)
    end
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

  def treat_my_farm
    json = get_scene("farm")
    farm = json["crops"]["main"].delete_if { |k, v| v.nil? }
    farm.each do |index, land|
      land["pest"].times do
        puts "[land.kill_pest] land_id: %d %s" % [index, pesters_name(land)]
        call_api("land.kill_pest", { :land_index => index })
      end
    end
    farm.each do |index, land|
      next unless land["water"] == -1 
      puts "[land.water] land_id: %d" % index
      call_api("land.water", { :land_index => index })
    end
    farm.each do |index, land|
      next unless land["state"] == "fruit"
      puts "[land.harvest] land_id: %d" % index
      call_api("land.harvest", { :land_index => index })
    end
    farm.each do |index, land|
      next unless land["state"] == "dead"
      puts "[land.clear] land_id: %d" % index
      call_api("land.clear", { :land_index => index })
    end
  end

  def treat_my_ranch
    json = get_scene("ranch")
    if json["sink"]["state"] == 1
      puts "[fold.water]"
      call_api("fold.water")
    end
    ranch = json["animals"]["main"].delete_if { |k, v| v.nil? }
    ranch.each do |index, fold|
      next unless fold["is_scare"]
      puts "[fold.cure] fold_id: %d" % index
      call_api("fold.cure", { :land_index => index })
    end
    ranch.each do |index, fold|
      next unless fold["state"] == "fruit"
      puts "[fold.harvest] fold_id: %d" % index
      call_api("fold.harvest", { :land_index => index })
    end
    ranch.each do |index, fold|
      next unless fold["state"] == "dead"
      call_api("fold.clear", { :land_index => index })
    end
  end

  def treat_friend_farm(friend_id)
    json = get_scene("farm", friend_id)
    farm = json["crops"]["main"].delete_if { |k, v| v.nil? }
    farm.each do |index, land|
      next if land["pester"].include?(@my_id)
      land["pest"].times do
        puts "[land.friend.kill_pest] mixi: %s, land_id: %d %s" % [friend_name(friend_id), index, pesters_name(land)]
        call_api("land.friend.kill_pest", {
          :land_index => index,
          :friend_id => friend_id,
        })
      end
    end
    farm.each do |index, land|
      next unless land["water"] == -1 
      puts "[land.friend.water] mixi: %s, land_id: %d" % [friend_name(friend_id), index]
      call_api("land.friend.water", {
        :land_index => index,
        :friend_id => friend_id,
      })
    end
    farm.each do |index, land|
      next unless land["state"] == "fruit"
      next if land["total_fruit"].to_i <= 25
      next if land["stealer"].include?(@my_id)
      next if land["caught_stealer"].include?(@my_id)
      puts "[land.friend.steal] mixi: %s, land_id: %d" % [friend_name(friend_id), index]
      call_api("land.friend.steal", {
        :land_index => index,
        :friend_id => friend_id,
      })
    end
  end

  def treat_friend_ranch(friend_id)
    json = get_scene("ranch", friend_id)
    if json["sink"]["state"] == 1
      puts "[fold.friend.water] mixi: %s" % friend_name(friend_id)
      call_api("fold.friend.water", { :friend_id => friend_id })
    end
    ranch = json["animals"]["main"].delete_if { |k, v| v.nil? }
    ranch.each do |index, fold|
      next unless fold["is_scare"]
      puts "[fold.friend.cure] mixi: %s, fold_id: %d" % [friend_name(friend_id), index]
      call_api("fold.friend.cure", {
        :land_index => index,
        :friend_id => friend_id,
      })
    end
    ranch.each do |index, fold|
      total = fold["auto_harvest"].inject(0) { |t, i| t += i }
      limit = fold["auto_harvest"].size * 25
      next if total <= limit
      next if fold["stealer"].include?(@my_id)
      puts "[fold.friend.steal] mixi: %s, fold_id: %d" % [friend_name(friend_id), index]
      result = call_api("fold.friend.steal", {
        :land_index => index,
        :friend_id => friend_id,
      })
    end
  end
end


def main
  email = nil
  password = nil
  community_id = nil
  mixi_id = nil
  ARGV.options do |opt|
    opt.on("-e", "--email ADDRESS") { |v| email = v }
    opt.on("-p", "--password PASSWORD") { |v| password = v }
    opt.on("-c", "--community COMMUNITY_ID") { |v| community_id = v.to_i }
    opt.on("-i", "--id MIXI_ID") { |v| mixi_id = v.to_i }
    opt.parse!
  end
  return unless email && password
  queue = Queue.instance
  farm_thread = Thread.new do
    puts "[thread] start"
    loop do
      while (friend_ids = queue.pop(1000)).empty?
        puts "[thread] sleep"
        sleep 1
      end
      mixi_app = Mixi.new(email, password)
      mx_farm = MxFarm.new
      mx_farm.login(mixi_app, friend_ids.compact)
      friends = mx_farm.get_friends
      mx_farm.treat_my_farm
      mx_farm.treat_my_ranch
      mx_farm.treat_friends
      break if friend_ids.last.nil?
    end
    puts "[thread] end"
  end
  mixi = Mixi.new(email, password)
  if community_id
    num = mixi.community_size(community_id)
    pages_list = (1..(num / 50)).to_a.sort_by { |i| rand }
    pages_list.each do |page_id|
      while queue.size > 10000
        sleep 1
      end
      puts "[get_members] page_id: %d (queue_size: %d)" % [page_id, queue.size]
      members = mixi.community_members(community_id, page_id)
      queue.push members
      sleep 10
    end
  elsif mixi_id
    queue.push mixi_id
  else
    mixi.get_session_token(MxFarm::APP_ID)
    friend_ids = mixi.get_viewer_friends.map { |f| f["id"] }
    queue.push friend_ids
  end
  queue.push nil
  farm_thread.join
end

main
