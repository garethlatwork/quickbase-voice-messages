
require 'sinatra'
require 'quickbase_client'
require 'twilio-ruby'
require 'yaml'
require 'iron_worker'
require_relative 'send_message_job'

configure do
  config = YAML.load_file("config.yml") 
  if settings.environment == :production
    use Rack::SslEnforcer
    set :site_url, config["development_url"]
  else
    set :site_url, config["production_url"]
  end
end

not_found do
  redirect '/home.html'
end

get '/' do
  redirect '/home.html'
end

# Called by Twilio
post '/play_message' do
   error_msg = "We're sorry. An error has occurred in our system."
   begin
      text, error_msg = get_text_from_quickbase(params)
   rescue StandardError => error
      puts error
      puts params.inspect.to_s
   end
   builder do |xml|
     xml.instruct!
     xml.Response do
       xml.Say (text || error_msg)
     end  
  end  
end

# Called by QuickBase user's form or code
post '/send_message' do 
   parameters = params_to_sym(params)
   link = "<a href=\"https://#{parameters[:realm]}.quickbase.com/db/#{parameters[:dbid]}?a=dr&rid=#{parameters[:rid]}\">https://#{parameters[:realm]}.quickbase.com/db/#{parameters[:dbid]}?a=dr&rid=#{parameters[:rid]}</a>"
   ret = "Failed: Please check this link: #{link}"
   begin
      text, error_msg = get_text_from_quickbase(params) 
      if text
         client = Twilio::REST::Client.new(parameters[:account_sid], parameters[:auth_token])
         call = client.account.calls.create(
           :from => "+#{parameters[:from]}",
           :to => "+#{parameters[:to]}",
           :url => "#{settings.site_url}/play_message?appdbid=#{parameters[:appdbid]}&dbid=#{parameters[:dbid]}&rid=#{parameters[:rid]}&fid=#{parameters[:fid]}&username=#{parameters[:username]}&password=#{parameters[:password]}"
         )
         ret = "Succeeded"
      end
   rescue StandardError => error
      puts error
      puts error.backtrace
      puts parameters.inspect.to_s
      puts ret
   end
   ret
end

# Called by QuickBase user's form or code
post '/send_bulk_voice_messages' do
   parameters = params_to_sym(params)    
   send_bulk_voice_messages(parameters,"#{settings.site_url}/send_message")
end

private

def get_qbc(params)
   qbc = QuickBase::Client.init({ "username" => params[:username], 
                                            "password" => params[:password], 
                                            "org" => params[:realm], 
                                            "apptoken" => params[:apptoken] })
   qbc.cacheSchemas=true
   qbc
end

def get_text_from_quickbase(params)
   text  = nil
   error_msg = "We're sorry. An error has occurred in our system."
   begin
      qbc = get_qbc(params)
      text = qbc.getRecord(params[:rid],params[:dbid],[params[:fid]])
      if text
        text = text[params[:fid]] 
      else
        app_error_msg = qbc.getDBvar(params[:appdbid],"voice_mail_error_message") 
        error_msg = app_error_msg if app_error_msg
      end
   rescue StandardError => error
      puts error
   end
   return text, error_msg
end

def send_bulk_voice_messages(params,url)
   begin
      ret = "<h2>Bulk messages are being sent in the background using <a href=\"http://www.iron.io/products/worker\">IronWorker</a></h2>"
      qbc = get_qbc(params)
      qbc.getSchema(params[:appdbid])
      if qbc.requestSucceeded
         ironworker_token = qbc.getDBvar(params[:appdbid],"ironworker_token")
         ironworker_project_id = qbc.getDBvar(params[:appdbid],"ironworker_project_id")
         twilio_account_sid = qbc.getDBvar(params[:appdbid],"twilio_account_sid")
         twilio_auth_token = qbc.getDBvar(params[:appdbid],"twilio_auth_token")
         twilio_outbound_phone_number = qbc.getDBvar(params[:appdbid],"twilio_outbound_phone_number")
         if ironworker_token and ironworker_project_id and twilio_account_sid and twilio_auth_token and twilio_outbound_phone_number
            qbc.getSchema(params[:dbid])
            if qbc.requestSucceeded
               clist = qbc.getColumnListForQuery(nil,"Pending Voice Messages")
               if clist and clist.length > 4
                  field_ids = {}
                  clist.split(/\./).each{|c|
                     field_name = qbc.lookupFieldNameFromID(c,params[:dbid]) 
                     field_ids[field_name] = c.dup if ["Record ID#","Phone","Message","Sent"].include?(field_name)
                  }
                  if field_ids.length >= 4
                     qbc.iterateRecords(params[:dbid],["Record ID#","Phone","Message"],nil,nil,"Pending Voice Messages"){|record|
                        if record["Record ID#"].length > 0 and record["Phone"].length > 4 and record["Message"].length > 0
                           send_message(url,
                                               ironworker_token,ironworker_project_id,
                                               twilio_account_sid, twilio_auth_token, twilio_outbound_phone_number,
                                               record["Phone"], 
                                               params[:username], params[:password],
                                               params[:appdbid], params[:dbid], record["Record ID#"], field_ids["Message"])
                        end                      
                     }
                  else
                     ret = "<p>The 'Pending Voice Messages' report in table #{params[:dbid]} must contain these fields:</p>"
                     ret << "<ol>"
                     ret << "<li>Record ID#</li>"
                     ret << "<li>Phone</li>"
                     ret << "<li>Message</li>"
                     ret << "<li>Sent</li>"
                     ret << "</ol>"
                  end      
               else
                  ret = "<h2>Table #{params[:dbid]} must have a 'Pending Voice Messages' report.</h2>"
                  ret << "<p>The report must contain these fields:</p>"
                  ret << "<ol>"
                  ret << "<li>Record ID#</li>"
                  ret << "<li>Phone</li>"
                  ret << "<li>Message</li>"
                  ret << "<li>Sent</li>"
                  ret << "</ol>"
               end   
            else
               ret = "<h2>Unable to access table #{params[:dbid]}</h2>"
            end
         else   
            ret = "<h2>Application #{params[:appdbid]} must have these application variables: </h2>"
            ret << "<ol>"
            ret << "<li>ironworker_token</li>"
            ret << "<li>ironworker_project_id</li>"
            ret << "<li>twilio_account_sid</li>"
            ret << "<li>twilio_auth_token</li>"
            ret << "<li>twilio_outbound_phone_number</li>"
            ret << "</ol>"
         end
      else   
         ret = "<h2>Unable to access application #{params[:appdbid]}</h2>"
      end   
   rescue StandardError => error
      ret = "<h2>Program error: #{error}</h2>"
      puts error
      puts params.inspect.to_s
      puts url
      puts ret
   end
   ret
end

def config_iron_worker(ironworker_token,ironworker_project_id)
   IronWorker.configure {|iwconfig|
      iwconfig.token = ironworker_token
      iwconfig.project_id = ironworker_project_id
   }
end
 
def send_message(url,
                             ironworker_token,
			     ironworker_project_id,
                             account_sid, auth_token, outbound_phone_number,
                             to, username, password,
                             appdbid, dbid, rid,  fid )
   config_iron_worker(ironworker_token,ironworker_project_id)
   smj = SendMessageJob.new
   iw_params = {}
   iw_params[:account_sid] = account_sid.dup
   iw_params[:auth_token] = auth_token.dup
   iw_params[:from] = outbound_phone_number.dup
   iw_params[:to] = to.dup
   iw_params[:username] = username.dup
   iw_params[:password] = password.dup
   iw_params[:appdbid] = appdbid.dup
   iw_params[:dbid] = dbid.dup
   iw_params[:rid] = rid.dup
   iw_params[:fid] = fid.dup
   smj.params = iw_params
   smj.url = url.dup
   smj.queue
end

def params_to_sym(params)
   syms = {}
   if params
      params.each{|k,v|syms[k.to_sym] = v.dup }
   end
   syms[:realm] ||= "www"
   syms
end
