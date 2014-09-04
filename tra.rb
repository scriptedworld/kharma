
require 'json'
require 'yaml'

require 'awesome_print'
require 'log4r'
require 'sqlite3'

include Log4r

# Place holder classes for different exception types
class NotFoundException < Exception; end
class BadDataException < Exception; end
class BadURLException < Exception; end

class TRA

  def self.instance( config_filepath = './tra.yaml',
                     db_filepath = './tra.db',
                     log_filepath = './tra.log' )
    if @instance.nil?
      @instance = TRA.new( config_filepath, db_filepath, log_filepath )
    end

    @instance
  end

  def initialize( config_filepath, db_filepath, log_filepath )
    @config_filepath = config_filepath
    @db_filepath     = db_filepath
    @log_filepath    = log_filepath

    # TODO: Assert that provided filepaths exist for config & db

    # Load config objects from config_filepath
    @request_configs = YAML.load_file( File.open( config_filepath ) )

    # Ensure each configuration object contains an appropriate historic attributes collection.
    @request_configs.each_value do |config|
      # Ensure the :historic_attributes key exists.
      config[ :historic_attributes ] ||= []
      # Add our required values.
      config[ :historic_attributes ] += %w( created modified )
      # Now remove duplicates.
      config[ :historic_attributes ].uniq!
    end

    puts 'Run-time Configuration:'
    ap( @request_configs )

    @db = SQLite3::Database.new( db_filepath )
    @db.results_as_hash = true

    @log = Logger.new( 'tra' )
    @log.outputters = FileOutputter.new( 'tra_log_file', filename: @log_filepath, trunc: false )
    @log.level = Log4r::DEBUG
  end

  def this_method
    # we only care about the first level of caller, so limit how much work caller has to do.
    first_caller = caller[ 0 ]
    # Next we only want the part of the string in quotes.
    parts = first_caller.split( '`', 2 )
    # finally remove the single quote from the end of the string.
    parts.last[ 0..-2 ]
  end

  def log( message, level = :debug )
    @log.send( level, "#{ this_method }: #{ message }" )
  end

  def output_json( data, status_code = 200 )
    [ status_code, { 'Content-Type' => 'application/x-json' }, data.to_json ]
  end

  # Output a result ( unhappy case, exception raised ) built from the error information captured in the exception.
  def output_error( error, status_code )
    result = {}
    result[ 'inspect' ] = error.inspect
    result[ 'backtrace' ] = error.backtrace

    log( error.inspect, :error )
    log( error.backtrace )

    output_json( result, status_code )
  end

  # This wraps execution to return an error to the user automatically without a lot of duplication.
  # It also automatically pulls the request body and passes it to the expected/required block.
  def with_protection( request_input = '', &_block )

    log( '** Request Processing Initiated' )

    # # Log EVERYTHING
    # log( env.ai )

    # Prepare to run given code block within a database transaction.
    result = nil

    # Attempt to parse the input body
    input_data = nil
    input_data = JSON.parse( request_input ) unless request_input.empty?

    # Run the transaction, execute the block, and capture it's result.
    # NOTE: If NO exception is raised, the transaction will close and call #commit automatically.
    # NOTE: If AN exception is raised, the transaction will close and call #rollback automatically.
    @db.transaction do
      result = yield input_data
    end

    # Finally output the result ( happy case, no exceptions )
    if result.nil? || result.empty?
      [ 204, {}, '' ]
    else
      output_json( result )
    end

  rescue BadURLException => e
    output_error( e, 404 )
  rescue BadDataException => e
    output_error( e, 400 )
  rescue NotFoundException => e
    output_error( e, 404 )
  rescue => e
    output_error( e, 500 )

  ensure
    log( '** Request Processing Complete' )
  end

  def run_query( query, *args, &block )
    log( query )
    log( args ) unless args.empty?

    # Ensure we have foreign keys turned on all the time.
    @db.execute( 'PRAGMA foreign_keys=ON ;' )
    @db.query( query, *args, &block )
  end

  def ensure_id_numeric( id )
    raise( BadDataException, 'ID is non-numeric' ) unless id =~ /^\d+$/
  end

  # Ensure all provided keys are not empty strings. No point in empty strings here.
  def ensure_params_not_empty( input, exception_param_names = [] )
    input.each_pair do |key, value|
      next if exception_param_names.include?( key )

      raise( BadDataException, "Empty/Nil value provided for input key: #{ key }" ) if value.nil? || ( value.respond_to?( :empty? ) && value.empty? )
    end
  end

  # Ensure the input hash contains elements with the given (required_attributes) keys.
  def ensure_params_exist( input, required_attributes )
    raise( BadDataException, "Missing required params. Expected list includes: #{ required_attributes.join( ', ' ) }" ) unless required_attributes.all? { |a| input.key?( a ) }
  end

  def ensure_record_exists( table_name, id )
    record_found = false

    qry = "SELECT id FROM #{ table_name } WHERE id=? ;"
    run_query( qry, [ id ] ) do |rst|
      rst.each { |_row| record_found = true }
    end

    raise( NotFoundException, "No #{ table_name } found with ID: #{ id }" ) unless record_found
  end

  def delete_item( config_object, id )
    table_name = config_object[ :table_name ]

    ensure_record_exists( table_name, id )

    qry = "DELETE FROM #{ table_name } WHERE id=? ;"
    run_query( qry, [ id ] )

    # Nothing to return.
    nil
  end

  def get_item_list( config_object, where_clause = '', clause_params = [] )
    table_name          = config_object[ :table_name ]
    required_attributes = config_object[ :required_attributes ]
    optional_attributes = config_object[ :optional_attributes ]
    historic_attributes = config_object[ :historic_attributes ]

    result = []

    qry = "SELECT * FROM #{ table_name } #{ where_clause } ;"
    run_query( qry, clause_params ) do |rst|
      rst.each do |row|
        row_hash = {}
        row_hash[ 'id' ] = row[ 'id' ]

        required_attributes.each { |a| row_hash[ a ] = row[ a ] }
        optional_attributes.each { |a| row_hash[ a ] = row[ a ] }
        historic_attributes.each { |a| row_hash[ a ] = row[ a ] }

        result << row_hash
      end
    end

    result
  end

  # Used by get_attributes. Please do not call this directly.
  def get_required_attributes( config_object, id )
    table_name          = config_object[ :table_name ]
    required_attributes = config_object[ :required_attributes ]
    optional_attributes = config_object[ :optional_attributes ]

    result = {}

    # Insert the values of each required attribute into the result hash.
    qry = "SELECT * FROM #{ table_name } WHERE id=? ;"
    run_query( qry, [ id ] ) do |rst|
      rst.each do |row|
        required_attributes.each { |a| result[ a ] = row[ a ] }
        optional_attributes.each { |a| result[ a ] = row[ a ] }
      end
    end

    result
  end

  # Used by get_attributes. Please do not call this directly.
  def get_metadata_attributes( config_object, id )
    table_name = config_object[ :table_name ]

    result = {}

    # Now insert the values of each optional attribute found in the project_metadata.
    qry = "SELECT * FROM #{ table_name }_metadata WHERE #{ table_name }_id=? ;"
    run_query( qry, [ id ] ) do |rst|
      rst.each do |row|
        key, value = row[ 'name' ], row[ 'value' ]
        result[ key ] = value
      end
    end

    result
  end

  # Used by get_attributes.  Not to be called directly.
  def get_historic_attributes( config_object, id )
    table_name          = config_object[ :table_name ]
    historic_attributes = config_object[ :historic_attributes ]

    result = {}

    # Insert each historic attribute
    qry = "SELECT * FROM #{ table_name } WHERE id=? ;"
    run_query( qry, [ id ] ) do |rst|
      rst.each do |row|
        historic_attributes.each { |a| result[ a ] = row[ a ] }
      end
    end

    result
  end

  def get_attributes( config_object, id )
    table_name = config_object[ :table_name ]
    ensure_record_exists( table_name, id )

    result = {}
    result.merge! get_required_attributes( config_object, id )
    result.merge! get_metadata_attributes( config_object, id )
    result.merge! get_historic_attributes( config_object, id )
    result
  end

  # NOTE: We can't do assure params here because updates may or may not include all required fields
  #       ( record required, not action required )
  def update_attributes( config_object, id, input_data )
    table_name          = config_object[ :table_name ]
    required_attributes = config_object[ :required_attributes ]
    optional_attributes = config_object[ :optional_attributes ]

    ensure_record_exists( table_name, id )
    ensure_params_not_empty( input_data, optional_attributes )

    # Update any 'REQUIRED' attributes we found in the update body.
    # NOTE: Required in this context are attributes that are part of the record and not metadata.)
    required_attributes.each do |a|
      next unless input_data.keys.include?( a )

      qry = "UPDATE #{ table_name } SET #{ a }=? WHERE id=? ;"
      run_query( qry, [ input_data[ a ], id ] )
    end

    # Update any 'OPTIONAL' attributes we found in the update body.
    # NOTE: Optional in this context are attributes that are part of the record and not metadata but are not required.)
    optional_attributes.each do |a|
      next unless input_data.keys.include?( a )

      qry = "UPDATE #{ table_name } SET #{ a }=? WHERE id=? ;"
      run_query( qry, [ input_data[ a ], id ] )
    end

    # Update any metadata attributes we found in the update body.
    # NOTE: Optional in this context means attributes that are stored in the *_metadata table.
    metadata_keys = ( input_data.keys - required_attributes )
    metadata_keys.each do |k|
      qry = "INSERT OR REPLACE INTO #{ table_name }_metadata ( #{ table_name }_id, name, value ) VALUES ( ?, ?, ? ) ;"
      run_query( qry, [ id, k, input_data[ k ] ] )
    end

    # Return id of updated record.
    { 'id' => id }
  end

  # We only allow the deletion of metadata records. Updates to required &| optional attribute go through "update"
  def delete_meta_attributes( config_object, id, input_data )
    table_name = config_object[ :table_name ]
    ensure_record_exists( table_name, id )

    raise( BadDataException, 'Input data should be an array.' ) unless input_data.instance_of?( Array )
    raise( BadDataException, 'Input data must contain at least one element.' ) if input_data.empty?

    input_data.each do |field_name|
      qry = "DELETE FROM #{ table_name }_metadata WHERE #{ table_name }_id = ? AND name = ? ;"
      run_query( qry, [ id, field_name ] )
    end

    # Return id of updated record.
    { 'id' => id }
  end

  def insert_attributes( config_object, input_data )
    table_name          = config_object[ :table_name ]
    required_attributes = config_object[ :required_attributes ]
    optional_attributes = config_object[ :optional_attributes ]

    # Make sure everything we must have exists ( or the INSERT will fail ).
    ensure_params_exist( input_data, required_attributes )
    ensure_params_not_empty( input_data, optional_attributes )

    # Build a bit of metadata for the INSERT query. We need the field list, placeholding '?' for each field,
    # and a copy of the value of each field in appropriate arrays.
    fields = required_attributes.select { |a| input_data.keys.include?( a ) }
    place_holders = []
    values = []

    fields.each do |f|
      place_holders << '?'
      values << input_data[ f ]
    end

    optional_attributes.each do |a|
      next unless input_data.keys.include?( a )

      fields << a
      place_holders << '?'
      values << input_data[ a ]
    end

    # Do INSERT & retrieve row_id.
    qry = "INSERT INTO #{ table_name } ( #{ fields.join( ', ' ) } ) VALUES ( #{ place_holders.join( ', ' ) } ) ;"
    run_query( qry, values )

    id = @db.last_insert_row_id

    # Insert *_metadata records an any additional parameters included in the create request body.
    metadata_keys = ( input_data.keys - required_attributes - optional_attributes )
    metadata_keys.each do |k|
      qry = "INSERT INTO #{ table_name }_metadata ( #{ table_name }_id, name, value ) VALUES ( ?, ?, ? ) ;"
      run_query( qry, [ id, k, input_data[ k ] ] )
    end

    # Finally, return the ID of the freshly created record.
    { 'id' => id }
  end

  def config( type )
    raise( BadURLException, 'Invalid type requested: #{ type }' ) unless @request_configs.key?( type )
    @request_configs[ type ]
  end

  def terminate
    log( 'SIGINT caught. Exitting.', :fatal )
    @db.close
    exit( 0 )
  end

  ### END POINT HANDLERS #############################################################################################

  # This method exists only to ensure the database is in a known state during testing.
  # TODO: Add code to ONLY expose this method in the test environment.
  def clear
    with_protection do
      qry = 'DELETE FROM project ;'
      run_query( qry )
      { 'status' => 'OK' }
    end
  end

  # List all items of a given type. ie. /project(s) /run(s) /result(s)
  def list_type_items( type )
    with_protection do
      cfg = config( type )
      get_item_list( cfg )
    end
  end

  # Get a specific item. ie. /project(s)/1
  def get_specific_type_item( type, id )
    with_protection do
      ensure_id_numeric( id )

      cfg = config( type )
      get_attributes( cfg, id )
    end
  end

  # Update a specific item
  def update_specific_type_item( type, id, request_body )
    with_protection( request_body ) do |input_data|
      ensure_id_numeric( id )
      cfg = config( type )
      update_attributes( cfg, id, input_data )
    end

  end

  # delete a specific item ( and all sub data )
  # NOTE: this method also, should only exist in test environment.
  def delete_specific_type_item( type, id )
    with_protection do
      ensure_id_numeric( id )

      cfg = config( type )
      delete_item( cfg, id )
    end
  end

  # Remove metadata attributes from the specified item. Use update to change required &| optional attributes.
  def remove_attributes_for_specific_type_item( type, id, request_body )
    with_protection( request_body ) do |input_data|
      ensure_id_numeric( id )

      cfg = config( type )

      # Delete any remaining fields after the above sanity check.
      delete_meta_attributes( cfg, id, input_data )
    end
  end

  # Create an item.
  def create_type_item( type, request_body )
    with_protection( request_body ) do |input_data|
      cfg = config( type )
      insert_attributes( cfg, input_data )
    end
  end

  def list_specific_type_item_subtype_items( type, id, subtype )
    with_protection do
      ensure_id_numeric( id )

      cfg = config( type )

      raise( BadURLException, "Invalid subtype requested: #{ subtype } for #{ type }" ) unless cfg[ :allowed_subtypes ].include?( subtype )

      sub_cfg = config( subtype )

      ensure_record_exists( cfg[ :table_name ], id )

      get_item_list( sub_cfg, "WHERE #{ cfg[ :table_name ] }_id=?", [ id ] )
    end

  end

end
