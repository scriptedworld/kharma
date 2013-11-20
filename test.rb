#!/usr/bin/env ruby

require 'rubygems'

require 'awesome_print'
require 'httparty'
require 'json'

require 'minitest/spec'
require 'minitest/autorun'

require 'sqlite3'

class TRA
	include HTTParty

	base_uri 'http://localhost:1234'
	format :json

	def create_project( name, metadata = {} )
    # Fill in 'name' as it is the only known REQUIRED field for a TRA Project.
		input_data = { 'name' => name }
		input_data.merge! metadata

    TRA.post( '/projects/create', { :body => input_data.to_json } )
	end

	def update_project( id, input_data )
    TRA.put( "/projects/#{ id }", { :body => input_data.to_json } )
	end

	def get_project( id )
    TRA.get( "/projects/#{ id }" )
	end

end

class TRATests < MiniTest::Unit::TestCase

	def setup

		@host     = 'localhost'
		@port     = 1234            # hardcoded in server.rb @ line: 13
		@base_url = '/'

		@tra      = TRA.new

    db = SQLite3::Database.new( './tra.db' );
    db.query( "delete from project;" )

	end

	def this_method
		caller[0]=~/`(.*?)'/
		$1
	end

	def test_create_project

    # Step 1 - use known good type ( PROJECT ).

		result = @tra.create_project( this_method )

    # If we get back an ID field, that is a success.
    assert( result.include? 'id' )
    
    # Step 2 - Try to duplicate a project name.

		result2 = @tra.create_project( this_method )

    # If we get back an INSPECT field, that was an error.
    assert( result2.include? 'inspect' )
    refute( result2[ 'inspect' ].index( 'SQLite3::ConstraintException' ).nil? )

	end

  # NOTE: this test depends on test_create_project working.
  def test_get_project

    result = @tra.create_project( this_method )
    id = result['id']

		result = @tra.get_project( id )

    assert( result.include? 'name' )
    assert( result.include? 'created' )
    assert( result.include? 'modified' )

    assert( result[ 'name' ] == this_method )
    refute( result[ 'created' ].nil? )
    assert( result[ 'modified' ].nil? )

    result2 = @tra.get_project( 42 )
    
    assert( result2.include? 'inspect' )
    refute( result2[ 'inspect' ].index( 'NotFoundException' ).nil? )

  end


  # NOTE: this test depends on test_create_project && test_get_project working.
  def test_update_project
    result = @tra.create_project( this_method )
    id = result['id']

    result2 = @tra.update_project( id, { 'foo' => 'bar' } )
    assert( result.include? 'id' )
    assert( result[ 'id' ] == id )

    result3 = @tra.get_project( id )
    assert( result3.include? 'foo' )
    assert( result3[ 'foo' ] == 'bar' )
    refute( result3[ 'modified' ].nil? )

    # TODO: Add tests here for updating required fields to nil 
    #       ( or trying to update the ID of a record ).

  end

end
