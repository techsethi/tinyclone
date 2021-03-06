%w(rubygems sinatra haml dm-core dm-timestamps dm-types dm-migrations dm-transactions uri rest_client xmlsimple ./dirty_words).each  { |lib| require lib}
require 'awesome_print'
require 'debugger'
require 'uri'

disable :show_exceptions
enable :inline_templates

helpers do

  def protected!
    unless authorized?
      response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
      throw(:halt, [401, "Not authorized\n"])
    end
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == ['tcity', 'tcity']
  end

  def date_format(input_date)
    return 'N/A' if input_date.nil?
    return input_date.strftime("%Y-%m-%d %l:%M %P")
  end

end

get '/' do 
    protected!
    haml :index 
end

post '/' do
  uri = URI::parse(params[:original])
  custom = params[:custom].empty? ? nil : params[:custom]
  raise "Invalid URL : #{params[:original]}" unless uri.kind_of? URI::HTTP or uri.kind_of? URI::HTTPS
  # raise "Only Timescity.com URLs can be shortened. [Invalid : #{params[:original]}]" unless uri.host.downcase == "timescity.com"
  @link = Link.shorten(params[:original], custom) 
  puts @link
  haml :index
end

['/info/:short_url', '/info/:short_url/:num_of_days', '/info/:short_url/:num_of_days/:map'].each do |path|
  get path do
    protected!
    @link = Link.first(:identifier => params[:short_url])
    raise 'This link is not defined yet' unless @link
    @num_of_days = (params[:num_of_days] || 15).to_i
    @count_days_bar = Visit.count_days_bar(params[:short_url], @num_of_days)
    chart = Visit.count_country_chart(params[:short_url], params[:map] || 'world')
    @count_country_map = chart[:map]
    @count_country_bar = chart[:bar]
    haml :info
  end
end

['/visits/:short_url'].each do |path|
  get path do
    protected!
    @visits = Visit.all(:link_identifier => params[:short_url], :order => [:created_at.desc])
    raise 'This link is not defined yet' unless @visits
    haml :visits
  end
end


get "/list" do
    protected!
    @links = Link.all(:order => [:created_at.desc])
    haml :list
end

get "/delete/:identifier_to_delete" do
    protected!
    @link = Link.get(params[:identifier_to_delete])
    @link.destroy
    @message = "Link '#{params[:identifier_to_delete]}' has been deleted."
    @links = Link.all
    haml :list
end
    
get '/:short_url' do 
  link = Link.first(:identifier => params[:short_url])
  if link.nil?
      status 404
      haml :no_target
  else      
      link.visits << Visit.create(:ip => get_remote_ip(env),
                                  :http_user_agent =>  env['HTTP_USER_AGENT'],
                                  :http_referer => env['HTTP_REFERER']
                  )
      link.save
      redirect link.url.original, 302
  end      
end

error do haml :index end

def get_remote_ip(env)
  if addr = env['HTTP_X_FORWARDED_FOR']
    addr.split(',').first.strip
  else
    env['REMOTE_ADDR']
  end
end

DataMapper.setup(:default, ENV['DATABASE_URL'] 
# DataMapper.setup(:default, ENV['DATABASE_URL'] || 'mysql://root:root@localhost/tc_tiny_urls')

class Url
  include DataMapper::Resource
  property  :id,          Serial
  property  :original,    String, :length =>  1024
  belongs_to  :link
end

class Link
  include DataMapper::Resource
  property  :identifier,  String, :key => true
  property  :created_at,  DateTime 
  has 1, :url
  has n, :visits
  
  def self.shorten(original, custom=nil)
    url = Url.first(:original => original) 
    return url.link if url    
    link = nil
    if custom
      raise 'Someone has already taken this custom URL, sorry' unless Link.first(:identifier => custom).nil?
      raise 'This custom URL is not allowed because of profanity' if DIRTY_WORDS.include? custom
      transaction do |txn|
        link = Link.new(:identifier => custom)
        link.url = Url.create(:original => original)
        link.save        
      end
    else
      transaction do |txn|
        link = create_link(original)
        puts "link"
        ap link
      end    
    end
    return link
  end
  
  private
  
  def self.create_link(original)
    url = Url.new(:original => original)
    # debugger
    
    max_id = Url.max.id + 10001
    identified_to_store = max_id.to_s(36)  
    if Link.first(:identifier => identified_to_store).nil? or !DIRTY_WORDS.include? url.id.to_s(36)
      link = Link.new(:identifier => identified_to_store)
      link.url = url
      link.save 
      return link     
    else
      create_link(original)
    end    
  end
end

class Visit
  include DataMapper::Resource
  
  property  :id,          Serial
  property  :created_at,  DateTime
  property  :ip,          IPAddress
  property  :country,     String
  property  :http_user_agent,   String, :length =>  1024
  property  :http_referer,  String, :length =>  1024
  belongs_to  :link
  
  after :create, :set_country
  
  def set_country
    xml = RestClient.get "http://api.hostip.info/get_xml.php?ip=#{ip}"  
    self.country = XmlSimple.xml_in(xml.to_s, { 'ForceArray' => false })['featureMember']['Hostip']['countryAbbrev']
    self.save
  end
  
  def self.count_days_bar(identifier,num_of_days)
    visits = count_by_date_with(identifier,num_of_days)
    data, labels = [], []
    visits.each {|visit| data << visit[1]; labels << "#{visit[0].day}/#{visit[0].month}" }
    "http://chart.apis.google.com/chart?chs=820x180&cht=bvs&chxt=x&chco=a4b3f4&chm=N,000000,0,-1,11&chxl=0:|#{labels.join('|')}&chds=0,#{data.sort.last+10}&chd=t:#{data.join(',')}"
  end
  
  def self.count_country_chart(identifier,map)
    countries, count = [], []
    count_by_country_with(identifier).each {|visit| countries << visit.country; count << visit.count }
    chart = {}
    chart[:map] = "http://chart.apis.google.com/chart?chs=440x220&cht=t&chtm=#{map}&chco=FFFFFF,a4b3f4,0000FF&chld=#{countries.join('')}&chd=t:#{count.join(',')}"
    chart[:bar] = "http://chart.apis.google.com/chart?chs=320x240&cht=bhs&chco=a4b3f4&chm=N,000000,0,-1,11&chbh=a&chd=t:#{count.join(',')}&chxt=x,y&chxl=1:|#{countries.reverse.join('|')}"
    return chart
  end
  
  def self.count_by_date_with(identifier,num_of_days)
    visits = repository(:default).adapter.select("SELECT date(created_at) as date, count(*) as count FROM visits where link_identifier = '#{identifier}' and created_at between CURRENT_DATE-#{num_of_days} and CURRENT_DATE+1 group by date(created_at)")
    dates = (Date.today-num_of_days..Date.today)
    results = {}
    dates.each { |date|
      visits.each { |visit| results[date] = visit.count if visit.date == date }
      results[date] = 0 unless results[date]
    }
    results.sort.reverse    
  end
  
  def self.count_by_country_with(identifier)
    repository(:default).adapter.select("SELECT country, count(*) as count FROM visits where link_identifier = '#{identifier}' group by country")    
  end
end

DataMapper.finalize
# DataMapper::Logger.new(STDOUT,  :debug)
DataMapper.auto_upgrade!

__END__

@@ layout
!!! 1.1
%html
  %head
    %title Timescity Tiny URLs
    %link{:rel => 'stylesheet', :href => 'http://www.blueprintcss.org/blueprint/screen.css', :type => 'text/css'}  
  %body
    .container
      %p
      = yield
      #footer  
        %br
        %br
        %p  
          <a href="/">Home</a> <a href="/list">List</a> 
        %p 
        copyright @timescity ver 0.5     

@@ index
%h1.title Timescity Tiny URLs
- unless @link.nil?
  .success
    %code= @link.url.original
    has been shortened to 
    %a{:href => "/#{@link.identifier}"}
      = "http://tcity.me/#{@link.identifier}"
    %br
    Go to 
    %a{:href => "http://tcity.me/info/#{@link.identifier}"}
      = "http://tcity.me/info/#{@link.identifier}"
    to get more information about this link.
- if env['sinatra.error']
  .error= env['sinatra.error'] 
%form{:method => 'post', :action => '/'}
  Shorten this:
  %input{:type => 'text', :name => 'original', :size => '70'} 
  %input{:type => 'submit', :value => 'now!'}
  %br
  to http://tcity.me/
  %input{:type => 'text', :name => 'custom', :size => '20'} 
  (optional)

@@no_target
%h3.title URL doesn't exists [#{params[:short_url]}]     
%br
  Go to <a href="http://timescity.com">Home Page</a>

@@info
%h1.title Information
.span-3 Original
.span-21.last= @link.url.original  
.span-3 Shortened
.span-21.last
  %a{:href => "/#{@link.identifier}"}
    = "http://tcity.me/#{@link.identifier}"
.span-3 Date created
.span-21.last= @link.created_at
.span-3 Number of visits
.span-21.last= "#{@link.visits.size.to_s} visits"
    
%h2= "Number of visits in the past #{@num_of_days} days"
- %w(7 14 21 30).each do |num_days|
  %a{:href => "/info/#{@link.identifier}/#{num_days}"}
    ="#{num_days} days "
  |
%p
.span-24.last
  %img{:src => @count_days_bar}

%h2 Number of visits by country
- %w(world usa asia europe africa middle_east south_america).each do |loc|
  %a{:href => "/info/#{@link.identifier}/#{@num_of_days.to_s}/#{loc}"}
    =loc
  |
%p
.span-12
  %img{:src => @count_country_map}
.span-12.last
  %img{:src => @count_country_bar}
%p

@@ list
<!-- DataTables CSS -->
<link rel="stylesheet" type="text/css" href="http://ajax.aspnetcdn.com/ajax/jquery.dataTables/1.9.4/css/jquery.dataTables.css">
 
<!-- jQuery -->
<script type="text/javascript" charset="utf8" src="http://ajax.aspnetcdn.com/ajax/jQuery/jquery-1.8.2.min.js"></script>
 
<!-- DataTables -->
<script type="text/javascript" charset="utf8" src="http://ajax.aspnetcdn.com/ajax/jquery.dataTables/1.9.4/jquery.dataTables.min.js"></script>
%h1.title List of URLs
%h5= @message.nil? ? "" : @message
%table#data
  %thead
    %tr
      %th
      %th Tiny URL
      %th Original
      %th Created Date 
      %th Total Hits
      %th &nbsp;
  %tbody
    - count = 0
    - @links.each do |l|
      %tr
        %td= count = count + 1
        %td= "<a href = 'http://tcity.me/info/#{l.identifier}'>#{l.identifier}</a>"
        %td= l.url.original
        %td= date_format(l.created_at)
        %td= "<a href='/visits/#{l.identifier}'>#{l.visits.size}</a>"
        %td= "<a href='/delete/#{l.identifier}'>Delete</a>"
<script language='javascript'>
$(document).ready(function(){
$('#data').dataTable({
"iDisplayLength": 25
});
});
</script>

@@ visits
<!-- DataTables CSS -->
<link rel="stylesheet" type="text/css" href="http://ajax.aspnetcdn.com/ajax/jquery.dataTables/1.9.4/css/jquery.dataTables.css">
 
<!-- jQuery -->
<script type="text/javascript" charset="utf8" src="http://ajax.aspnetcdn.com/ajax/jQuery/jquery-1.8.2.min.js"></script>
 
<!-- DataTables -->
<script type="text/javascript" charset="utf8" src="http://ajax.aspnetcdn.com/ajax/jquery.dataTables/1.9.4/jquery.dataTables.min.js"></script>
%h1.title List of Visits
%h4= "For <a href='/#{params[:short_url]}'>#{params[:short_url]}</a>"
%h5= @message.nil? ? "" : @message
%table#data
  %thead
    %tr
      %th
      %th Timestamp
      %th IP
      %th HTTP User Agent
      %th HTTP Referer
  %tbody
    - count = 0
    - @visits.each do |l|
      %tr
        %td= count = count + 1
        %td= date_format(l.created_at)
        %td= "<a href='http://www.whois.net/ip-address-lookup/#{l.ip}'>#{l.ip}</a>"
        %td= l.http_user_agent.nil? ? "N/A" : l.http_user_agent
        %td= l.http_referer.nil? ? "N/A" : l.http_referer
<script language='javascript'>
$(document).ready(function(){
$('#data').dataTable({
"iDisplayLength": 50
});
});
</script>
