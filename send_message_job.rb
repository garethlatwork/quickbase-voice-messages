require 'simple_worker'
require 'httparty'

class SendMessageJob < SimpleWorker::Base
  attr_accessor :url
  attr_accessor :params
  def run
     puts url
     puts params.inspect.to_s
     options = {:body => params}
     response = HTTParty.post(url,options)
     puts response
  end
end
