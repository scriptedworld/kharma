#!/usr/bin/env ruby

require 'sinatra'

require './tra.rb'

set port: 1234

unless ARGV.length == 1
  puts( 'CONFIG FILE NOT PROVIDED. CANNOT CONTINUE.' )
  exit( 1 )
end

def request_body
  request_body = request.body
  request_body.rewind
  request_body.read
end

TRA.instance( ARGV.last )

# Catch Ctrl-C to exit cleanly.
trap( 'INT' ) { @tra.terminate }

########################################################################################################################
### Web Service END POINTS #############################################################################################

post '/clear' do
  TRA.instance.clear( request, env )
end

get '/:type' do |type|
  TRA.instance.list_type_items( type )
end

get '/:type/:id' do |type, id|
  TRA.instance.get_specific_type_item( type, id )
end

put '/:type/:id' do |type, id|
  TRA.instance.update_specific_type_item( type, id, request_body )
end

delete '/:type/:id' do |type, id|
  TRA.instance.delete_specific_type_item( type, id )
end

post '/:type/:id/remove_attributes' do |type, id|
  TRA.instance.remove_attributes_for_specific_type_item( type, id, request_body )
end

post '/:type/create' do |type|
  TRA.instance.create_type_item( type, request_body )
end

### Misc other UI for searching/listing.
## NOTE ######## PLEASE PLACE SPECIAL SEARCH FUNCTIONS ABOVE THE GENERIC FUNCTION OTHERWISE THEY WILL NOT GET USED.

#  GENERIC SEARCH FUNCTION: List subtype for type. ie. /project(s)/1/run(s)
get '/:type/:id/:subtype' do |type, id, subtype|
  TRA.instance.list_specific_type_item_subtype_items( type, id, subtype )
end
