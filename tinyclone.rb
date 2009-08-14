%w(rubygems sinatra haml dm-core dm-timestamps dm-types uri restclient xmlsimple dirty_words).each  { |lib| require lib}
disable :show_exceptions

get '/' do haml :index end

post '/' do
  uri = URI::parse(params[:original])
  custom = params[:custom].empty? ? nil : params[:custom]
  raise "Invalid URL" unless uri.kind_of? URI::HTTP or uri.kind_of? URI::HTTPS
  @link = Link.shorten(params[:original], custom) 
  haml :index
end

['/info/:short_url', '/info/:short_url/:num_of_days', '/info/:short_url/:num_of_days/:map'].each do |path|
  get path do
    @link = Link.first(:identifier => params[:short_url])
    raise 'This link is not defined yet' unless @link
    @num_of_days = (params[:num_of_days] || 15).to_i
    map = params[:map] || 'world'
    @count_chart = Visit.count_chart(params[:short_url], @num_of_days)
    @count_map = Visit.count_map(params[:short_url], map)
    haml :info
  end
end

get '/:short_url' do 
  link = Link.first(:identifier => params[:short_url])
  p request
  p env['REMOTE_ADDR']
  link.visits << Visit.create(:ip => env['REMOTE_ADDR'])
  link.save
  redirect link.url.original
end

error do haml :index end

use_in_file_templates!

DataMapper.setup(:default, ENV['DATABASE_URL'] || 'mysql://root:root@localhost/tinyclone')
class Url
  include DataMapper::Resource
  property  :id,          Serial
  property  :original,    String, :length => 255   
  belongs_to  :link
end

class Link
  include DataMapper::Resource
  property  :identifier,         String, :key => true
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
      end    
    end
    return link
  end
  
  private
  
  def self.create_link(original)
    url = Url.create(:original => original)
    if Link.first(:identifier => url.id.to_s(36)).nil? or !DIRTY_WORDS.include? url.id.to_s(36)
      link = Link.new(:identifier => url.id.to_s(36))
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
  belongs_to  :link
  
  after :create, :set_country
  
  def set_country
    xml = RestClient.get "http://api.hostip.info/get_xml.php?ip=#{ip}"  
    self.country = XmlSimple.xml_in(xml.to_s, { 'ForceArray' => false })['featureMember']['Hostip']['countryAbbrev']
    self.save
  end
  
  def self.count_chart(identifier,num_of_days)
    visits = count_by_date_with(identifier,num_of_days)
    data, labels = [], []
    visits.each {|visit| data << visit[1]; labels << "#{visit[0].day}/#{visit[0].month}" }
    "http://chart.apis.google.com/chart?chs=600x180&cht=bvs&chxt=x&chco=a4b3f4&chm=N,000000,0,-1,11&chxl=0:|#{labels.join('|')}&chds=0,#{data.sort.last+10}&chd=t:#{data.join(',')}"
  end
  
  def self.count_map(identifier,map)
    visits = count_by_country_with(identifier)
    countries, count = [], []
    visits.each {|visit| countries << visit.country; count << visit.count }
    "http://chart.apis.google.com/chart?chs=440x220&cht=t&chtm=#{map}&chco=FFFFFF,a4b3f4,0523a4&chld=#{countries.join('')}&chd=t:#{count.join(',')}"
  end
  
  def self.count_by_date_with(identifier,num_of_days)
    visits = repository(:default).adapter.query("SELECT date(created_at) as date, count(*) as count FROM visits where link_identifier = '#{identifier}' and created_at between CURRENT_DATE-#{num_of_days} and CURRENT_DATE+1 group by date(created_at)")
    dates = (Date.today-num_of_days..Date.today)
    results = {}
    dates.each { |date|
      visits.each { |visit| results[date] = visit.count if visit.date == date }
      results[date] = 0 unless results[date]
    }
    results.sort.reverse    
  end
  
  def self.count_by_country_with(identifier)
    repository(:default).adapter.query("SELECT country, count(*) as count FROM visits where link_identifier = '#{identifier}' group by country")    
  end
end

__END__

@@ layout
!!! 1.1
%html
  %head
    %title TinyClone
    %link{:rel => 'stylesheet', :href => 'http://www.blueprintcss.org/blueprint/screen.css', :type => 'text/css'}  
  %body
    .container
      = yield

@@ index
%h1.title TinyClone
- unless @link.nil?
  %code= @link.url.original
  has been shortened to 
  %a{:href => env['HTTP_REFERER'] + @link.identifier}
    = env['HTTP_REFERER'] + @link.identifier
- if env['sinatra.error']
  .error= env['sinatra.error'] 
%form{:method => 'post', :action => '/'}
  Shorten this:
  %input{:type => 'text', :name => 'original', :size => '70'} 
  %input{:type => 'submit', :value => 'now!'}
  %br
  to http://tinyclone.saush.com/
  %input{:type => 'text', :name => 'custom', :size => '20'} 
  (optional)
%p  
%small copyright &copy;
%a{:href => 'http://blog.saush.com'}
  Chang Sau Sheong
%p
  %a{:href => 'http://github.com/sausheong/tinyclone'}
    Full source code
    
@@info
%h1.title Information
.span-3 Original
.span-21.last= @link.url.original  
.span-3 Shortened
.span-21.last
  %a{:href => "/#{@link.identifier}"}
    = "http://tinyclone.saush.com/#{@link.identifier}"
.span-3 Date created
.span-21.last= @link.created_at
.span-3 Number of visits
.span-21.last #{@link.visits.size.to_s} visits
    
%h2 Number of visits in the past #{@num_of_days} days
- %w(7 14 21 30).each do |days|
  %a{:href => "/info/#{@link.identifier}/#{days}"}
    #{days} days 
  |
%p
.span-24.last
  %img{:src => @count_chart}

%h2 Number of visits in total by country
- %w(world usa asia europe africa middle_east south_america).each do |loc|
  %a{:href => "/info/#{@link.identifier}/#{@num_of_days.to_s}/#{loc}"}
    =loc
  |
%p
.span-24.last
  %img{:src => @count_map}    