require 'json'
require 'uri'
require 'httparty'
require 'httmultiparty'
require 'builder'
require 'time' 
require 'dotenv'

Dotenv.load

module SuperEHR

  def self.not_implemented(func)
    puts "ERROR: #{func} not implemented"
    raise NotImplementedError
  end

  class BaseEHR

    ### API SPECIFIC HOUSEKEEPING ###

    # initialize necessary components
    def initialize(default_params={})
      @default_params = default_params
    end

    def get_default_params
      return {}
    end

    def get_request_headers
      return {}
    end

    def get_request_body
      return {}
    end

    def get_request_url(endpoint)
      return "/#{endpoint}"
    end

    def refresh_token
      SuperEHR.not_implemented(__callee__)
    end

    # make a HTTP request
    def make_request(request_type, endpoint, request_params={}, use_default_params=true, to_json=true)
      if use_default_params
        params = get_default_params
        params = params.merge(request_params)
      else
        params = request_params
      end

      headers = get_request_headers
      url = get_request_url(endpoint)

      if request_type == "GET"
        response = HTTParty.get(url, :query => params, :headers => headers)
      elsif request_type == "POST"
        if headers.key?("Content-Type") and headers["Content-Type"] == "application/json"
          params = JSON.generate(params)
        end
        response = HTTParty.post(url, :body => params, :headers => headers)
      else
        puts "Request Type #{request_type} unsupported"
        return
      end

      if to_json
        return JSON.parse(response.body)
      else
        return response.body
      end
    end


    ### API CALLS ###

    # Get details for a specific patient
    def get_patient(patient_id)
      SuperEHR.not_implemented(__callee__)
    end

    # Gets a list of patients
    def get_patients
      SuperEHR.not_implemented(__callee__)
    end

    # Get a list of patients changed since ts
    def get_changed_patients(ts)
      SuperEHR.not_implemented(__callee__)
    end

    # Get a list of patients changed since ts
    def get_changed_patients_ids(ts)
      SuperEHR.not_implemented(__callee__)
    end

    # Get patients scheduled for a specific day
    def get_scheduled_patients(day)
      SuperEHR.not_implemented(__callee__)
    end

    # upload a pdf
    def upload_document(patient_id, filepath, description)
      SuperEHR.not_implemented(__callee__)
    end
  end

  class AllScriptsAPI < BaseEHR

    ### API SPECIFIC HOUSEKEEPING ###

    def initialize(ehr_username, ehr_password='', app_username, app_password, app_name, using_touchworks)

      # convert these to environment variables
      @app_username = app_username
      @app_password = app_password
      @app_name = app_name

      @ehr_username = ehr_username
      # if not using touchworks ehr, then professional ehr is used
      @using_touchworks = using_touchworks

      if (using_touchworks)
        base_url = "http://twlatestga.unitysandbox.com/unity/unityservice.svc"
      else
        base_url = "http://pro141ga.unitysandbox.com/Unity/unityservice.svc"
      end

      @uri = URI(base_url)
    end

    def get_default_params
      return {:Action => '', :AppUserID => @ehr_username, :Appname => @app_name,
        :PatientID => '', :Token => refresh_token,
        :Parameter1 => '', :Parameter2 => '', :Parameter3 => '',
        :Parameter4 => '', :Parameter5 => '', :Parameter6 => '', :Data => ''}
    end

    def refresh_token
      credentials = {:Username => @app_username, :Password => @app_password}
      # last two params prevents usage of default params and output to json
      return make_request("POST", "json/GetToken", credentials, false, false)
    end

    def get_request_headers
      return { 'Content-Type' => 'application/json' }
    end

    def get_request_url(endpoint)
      return "#{@uri}/#{endpoint}"
    end

    ### API CALLS ###

    #tested
    def get_patient(patient_id)
      params = {:Action => 'GetPatient', :PatientID => patient_id}
      response = make_request("POST", "json/MagicJson", params)[0]
      patient_info = {}
      if response.key?("getpatientinfo")
        if not response["getpatientinfo"].empty?
          patient_info = response["getpatientinfo"][0]
        end
      end
      return patient_info
    end

    def get_changed_patients(ts='')
      patient_ids = get_changed_patients_ids(ts)
      patients = []
      for id in patient_ids
        patients << get_patient(id)
      end
      return patients
    end

    def get_changed_patients_ids(ts='')
      params = {:Action => 'GetChangedPatients', :Parameter1 => ts}
      response = make_request("POST", "json/MagicJson", params)[0]
      patient_ids = []
      if response.key?("getchangedpatientsinfo")
        patient_ids = response["getchangedpatientsinfo"].map {|x| x["patientid"] }
      end
      return patient_ids
    end

    def get_scheduled_patients(day)
      params = {:Action => 'GetSchedule', :Parameter1 => day}
      response = make_request("POST", "json/MagicJson", params)[0]
      patients = []
      if response.key?("getscheduleinfo")
        if not response["getscheduleinfo"].empty?
          for schedule_block in response["getscheduleinfo"]
            patientid = schedule_block["patientID"]
            scheduled_patient = get_patient(patientid)
            patients << scheduled_patient
          end
        end
      end
      return patients
    end

    ## UPLOAD PDF IMPLEMENTATION ##

    def upload_document(patient_id, filepath, description)

      patient = get_patient(patient_id)
      first_name = patient["Firstname"]
      last_name = patient["LastName"]

      File.open(filepath, "r:UTF-8") do |file|
        file_contents = file.read()
        buffer = Base64.encode64(file_contents)

        # first call to push the contents
        save_pdf_xml = create_pdf_xml_params(first_name, last_name,
                                             filepath, file.size, 0, "false", "", "0")
        params = {:Action => 'SaveDocumentImage', :PatientID => patient_id,
          :Parameter1 => save_pdf_xml, :Parameter6 => buffer}
        out = make_request("POST", "json/MagicJson", params)
        # second call to push file information and wrap up upload
        doc_guid = out[0]["savedocumentimageinfo"][0]["documentVar"].to_s
        save_pdf_xml = create_pdf_xml_params(first_name, last_name,
                                             filepath, file.size, 0, "true", doc_guid, "0")
        params = {:Action => 'SaveDocumentImage', :PatientID => patient_id,
          :Parameter1 => save_pdf_xml, :Parameter6 => nil}
        out = make_request("POST", "json/MagicJson", params)
        return out
      end
    end

    # create XML parameters needed for upload_document
    def create_pdf_xml_params(first_name, last_name, file_name, bytes_read,
                              offset, upload_done, docs_guid, encounter_id, organization_name="TouchWorks")
      xml = Builder::XmlMarkup.new(:indent => 2)
      xml.doc do |b|
        b.item :name => "documentCommand", :value => "i"
        b.item :name => "documentType", :value => (@using_touchworks ? "sEKG" : "1")
        b.item :name => "offset", :value => offset
        b.item :name => "bytesRead", :value => bytes_read
        b.item :name => "bDoneUpload", :value => upload_done
        b.item :name => "documentVar", :value => docs_guid
        b.item :name => "vendorFileName", :value => file_name
        b.item :name => "ahsEncounterID", :value => 0
        b.item :name => "ownerCode", :value => get_provider_entry_code.strip
        b.item :name => "organizationName", :value => organization_name
        b.item :name => "patientFirstName", :value => first_name
        b.item :name => "patientLastName", :value => last_name
      end
      return xml.target!
    end

    private

    # necessary to create the xml params for upload_document
    def get_provider_entry_code()
      params = {:Action => 'GetProvider', :Parameter2 => @ehr_username}
      out = make_request("POST", "json/MagicJson", params)
      if @using_touchworks
        return out[0]["getproviderinfo"][0]["EntryCode"]
      else
        return out[1]["getproviderinfo1"][0]["EntryCode"]
      end
    end

    def get_encounter(patient_id)
      params = {:Action => 'GetEncounter', :PatientID => patient_id, :Parameter1 => "NonAppt",
        :Parameter2 => Time.new.strftime("%b %d %Y %H:%M:%S"), :Parameter3 => true,
        :Parameter4 => 'N'}
      out = make_request("POST", "json/MagicJson", params)
      return out[0]["getencounterinfo"][0]["EncounterID"]
    end
  end

  class AthenaAPI < BaseEHR

    ### API SPECIFIC HOUSEKEEPING ###

    def initialize(version, key, secret, practice_id)
      @uri = URI.parse('https://api.athenahealth.com')
      @version = version
      @key = key
      @secret = secret
      @practiceid = practice_id
    end

    def get_request_headers
      return { 'Authorization' => "Bearer #{refresh_token}" }
    end

    def get_request_url(endpoint)
      return "#{@uri}/#{@version}/#{@practiceid}/#{endpoint}"
    end

    def refresh_token
      auth_paths = {
        'v1' => 'oauth',
        'preview1' => 'oauthpreview',
        'openpreview1' => 'oauthopenpreview',
      }

      auth = {:username => @key, :password => @secret}

      url = "#{@uri}/#{auth_paths[@version]}/token"
      params = {:grant_type => "client_credentials"}
      response = HTTParty.post(url, :body => params, :basic_auth => auth)
      
      return response["access_token"]
    end


    ### API CALLS ###


    def get_patients
      patients = get_changed_patients("01/01/1900", 5000)
      return patients
    end

    def get_patient(patient_id)
      response = make_request("GET", "patients/#{patient_id}", {})
      patient_info = {}
      if not response[0].empty?
        patient_info = response[0]
      end
      return patient_info
    end

    def get_changed_patients(start_date, limit=5000, end_date=Time.new.strftime("%m/%d/%Y %H:%M:%S"))
      subscribe = make_request("GET", "patients/changed/subscription", {})
      if subscribe.has_key?("status") and subscribe["status"] == "ACTIVE"
        response = make_athena_request("patients/changed",
                                { :ignorerestrictions => false,
                                  :leaveunprocessed => false,
                                  :showprocessedstartdatetime => "#{start_date} 00:00:00",
                                  :showprocessedenddatetime => end_date,
                                  :limit => limit})
      else
        return []
      end
      return response
    end

    # start_date needs to be in mm/dd/yyyy
    # returns a list of patient ids that have been changed since start_date
    def get_changed_patients_ids(start_date, limit=5000, end_date=Time.new.strftime("%m/%d/%Y %H:%M:%S"))
      changed_patients = get_changed_patients(start_date, limit, end_date)
      patient_ids = []
      if changed_patients
        changed_patients.each do |changed_patient|
          patient_ids << changed_patient["patientid"]
        end
      end
      return patient_ids
    end


    ##Used to check credential of a client
    def valid_credentials?
      begin
        response = make_request("GET", "ping", {})
        if response["pong"] == "true"
          return true
        else 
          return false
        end
      rescue
        return false
      end
    end

    def get_scheduled_patients(date, department_id=1)
      response = make_request("GET", "appointments/booked",
                              {:departmentid => department_id, :startdate => date, :enddate => date})
      patients = []
      if not response["appointments"].empty?
        for appointment in response["appointments"]
          scheduled_patient = get_patient(appointment["patientid"].to_i)
          patients << scheduled_patient
        end
      end
      return patients
    end

    # might have issues if patient is in multiple departments
    def upload_document(patient_id, filepath, description, department_id=-1)
      endpoint = "patients/#{patient_id}/documents"
      headers = { 'Authorization' => "Bearer #{refresh_token}" }
      url = "#{@uri}/#{@version}/#{@practiceid}/#{endpoint}"
      params = {
        :departmentid => department_id != -1 ? department_id : get_patient(patient_id)["departmentid"],
        :attachmentcontents  => File.new(filepath),
        :documentsubclass    => "CLINICALDOCUMENT",
        :autoclose           => false,
        :internalnote        => description,
        :actionnote          => description }

        response = HTTMultiParty.post(url, :body => params, :headers => headers)
        return response
    end

    private

      # Iterates through the pagintized json responses
      def make_athena_request(endpoint, params={})
        result = []
        while endpoint
          data = make_request("GET", endpoint, params)
          if data["patients"]
            data["patients"].each do |patient| 
              result << patient
            end
          end
          endpoint = data["next"]
        end
        return result
      end
  end

  class Doc24Seven < BaseEHR
    attr_reader :access_token, :uri

    ### API SPECIFIC HOUSEKEEPING ###

    def initialize(args={})
      params = {
        :access_token => ''
      }
      params = params.merge(args)
      if (params[:access_token] == '' || params[:access_token] == nil)
        raise ArgumentError, "Access Token='#{params[:access_token]}' is blank or nil"
      end
      @access_token = params[:access_token]
      @uri = URI.parse(params[:base_url])
    end

    def get_request_headers
      return { 'X-Auth-Token' => "#{@access_token}"}
    end

    def get_request_url(endpoint)
      return "#{@uri}/#{endpoint}"
    end

    def get_access_token
      return @access_token
    end


    ### API CALLS ###

    #uploads record data to endpoint
    def upload_to_ehr(args)
      session_id = args[:patient].identifier
      patient_id = args[:patient].id
      pdf_file_path = args[:pdf_file_path]
      sound_file_path = args[:sound_file_path]
      recording_meta_data = args[:recording_meta_data]
      request = args[:request]

      headers = get_request_headers
      pdf_file = File.new(pdf_file_path)
      sound_file = File.new(sound_file_path)

      params = {
          :recordingMetadata => recording_meta_data,
          :audio => sound_file,
          :patientId => patient_id,
          :sessionId => session_id,
          :pdf => pdf_file
      }
      if request == "put"
        response = pdf_upload_request('put', params, headers)
      else
        response = pdf_upload_request('post', params, headers)
      end
      return response
    end

    private

    def pdf_upload_request(request, params, headers, document_id="")
      url = get_request_url("api/patients/" + params[:sessionId] + "/eko_upload")
      if request == 'put'
        response = HTTMultiParty.put(url, :query => params, :headers => headers)
      else
        response = HTTMultiParty.post(url, :query => params, :headers => headers)
      end
      return response
    end
  end

  class LifeLettersAPI < BaseEHR
    attr_reader :access_token, :uri

    ### API SPECIFIC HOUSEKEEPING ###

    def initialize(args={})
      params = {
        :access_token => ''
      }
      params = params.merge(args)
      if (params[:access_token] == '' || params[:access_token] == nil)
        raise ArgumentError, "Access Token='#{params[:access_token]}' is blank or nil"
      end
      @access_token = params[:access_token]
      @uri = URI.parse(params[:base_url])
    end

    def get_request_headers
      return { 'X-Auth-Token' => "#{@access_token}"}
    end

    def get_request_url(endpoint)
      return "#{@uri}/#{endpoint}"
    end

    def get_access_token
      return @access_token
    end


    ### API CALLS ###

    #uploads record data to endpoint
    def upload_to_ehr(args)
      #ideally patient id would be patient.id and session id should patient.identifier. but here we are.
      session_id = args[:patient].identifier
      patient_id = args[:patient].identifier
      pdf_file_path = args[:pdf_file_path]
      sound_file_path = args[:sound_file_path]
      recording_meta_data = args[:recording_meta_data]
      request = args[:request]

      headers = get_request_headers
      pdf_file = File.new(pdf_file_path)
      sound_file = File.new(sound_file_path)

      params = {
          :recordingMetadata => recording_meta_data.to_json,
          :audio => sound_file,
          :patientId => patient_id,
          :sessionId => session_id,
          :pdf => pdf_file
      }
      if request == "put"
        response = pdf_upload_request('put', params, headers)
      else
        response = pdf_upload_request('post', params, headers)
      end
      return response
    end

    private

    def pdf_upload_request(request, params, headers, document_id="")
      url = get_request_url("readings/eko_upload")

      if request == 'put'
        response = HTTMultiParty.put(url, :query => params, :headers => headers)
      else
        response = HTTMultiParty.post(url, :query => params, :headers => headers)
      end
      return response
    end
  end

  class EClinicalWorksSalesAPI < BaseEHR
    attr_reader :access_token, :uri

    ### API SPECIFIC HOUSEKEEPING ###

    def initialize(args={})
      params = {
        :access_token => ''
      }
      params = params.merge(args)
      if (params[:access_token] == '' || params[:access_token] == nil)
        raise ArgumentError, "Access Token='#{params[:access_token]}' is blank or nil"
      end
      @access_token = params[:access_token]
      @uri = URI.parse(params[:base_url])
    end

    def get_request_headers
      return { 'X-Auth-Token' => "#{@access_token}"}
    end

    def get_request_url(endpoint)
      return "#{@uri}/#{endpoint}"
    end

    def get_access_token
      return @access_token
    end


    ### API CALLS ###

    #uploads record data to endpoint
    def upload_to_ehr(args)
      session_id = args[:patient].identifier
      patient_id = args[:patient].identifier
      # ideally would be below, but expectations are currently identifier not id
      #patient_id = args[:patient].id
      pdf_file_path = args[:pdf_file_path]
      sound_file_path = args[:sound_file_path]
      recording_meta_data = args[:recording_meta_data]
      request = args[:request]

      headers = get_request_headers
      pdf_file = File.new(pdf_file_path)
      sound_file = File.new(sound_file_path)

      params = {
          :recordingMetadata => recording_meta_data,
          :audio => sound_file,
          :sessionId => session_id,
          :patientId => patient_id,
          :pdf => pdf_file
      }
      if request == "put"
        # post on purpose
        response = pdf_upload_request('post', params, headers)
      else
        response = pdf_upload_request('post', params, headers)
      end
      return response
    end

    private

    def pdf_upload_request(request, params, headers, document_id="")
      url = get_request_url("mobilesales/eko/patients/" + params[:sessionId] + "/eko_upload")

      if request == 'put'
        response = HTTMultiParty.put(url, :query => params, :headers => headers)
      else
        response = HTTMultiParty.post(url, :query => params, :headers => headers)
      end
      return response
    end
  end

  class EClinicalWorksAPI < BaseEHR
    attr_reader :access_token, :uri

    ### API SPECIFIC HOUSEKEEPING ###

    def initialize(args={})
      params = {
        :access_token => ''
      }
      params = params.merge(args)
      if (params[:access_token] == '' || params[:access_token] == nil)
        raise ArgumentError, "Access Token='#{params[:access_token]}' is blank or nil"
      end
      @access_token = params[:access_token]
      @uri = URI.parse(params[:base_url])
    end

    def get_request_headers
      return { 'X-Auth-Token' => "#{@access_token}"}
    end

    def get_request_url(endpoint)
      return "#{@uri}/#{endpoint}"
    end

    def get_access_token
      return @access_token
    end


    ### API CALLS ###

    #uploads record data to endpoint
    def upload_to_ehr(args)
      session_id = args[:patient].identifier
      patient_id = args[:patient].identifier
      # ideally would be allow; requirements otherwise for now
      #patient_id = args[:patient].id
      pdf_file_path = args[:pdf_file_path]
      sound_file_path = args[:sound_file_path]
      recording_meta_data = args[:recording_meta_data]
      request = args[:request]

      headers = get_request_headers
      pdf_file = File.new(pdf_file_path)
      sound_file = File.new(sound_file_path)

      params = {
          :recordingMetadata => recording_meta_data,
          :audio => sound_file,
          :sessionId => session_id,
          :patientId => patient_id,
          :pdf => pdf_file
      }
      if request == "put"
        # post on purpose
        response = pdf_upload_request('post', params, headers)
      else
        response = pdf_upload_request('post', params, headers)
      end
      return response
    end

    private

    def pdf_upload_request(request, params, headers, document_id="")
      url = get_request_url("mobile/eko/patients/" + params[:sessionId] + "/eko_upload")

      if request == 'put'
        response = HTTMultiParty.put(url, :query => params, :headers => headers)
      else
        response = HTTMultiParty.post(url, :query => params, :headers => headers)
      end
      return response
    end
  end

  class CallNineAPI < BaseEHR
    attr_reader :access_token, :uri

    ### API SPECIFIC HOUSEKEEPING ###

    def initialize(args={})
      params = {
        :access_token => ''
      }
      params = params.merge(args)
      if (params[:access_token] == '' || params[:access_token] == nil)
        raise ArgumentError, "Access Token='#{params[:access_token]}' is blank or nil"
      end
      @access_token = params[:access_token]
      @uri = URI.parse(params[:base_url])
    end

    def get_request_headers
      return { 'X-Auth-Token' => "#{@access_token}"}
    end

    def get_request_url(endpoint)
      return "#{@uri}/#{endpoint}"
    end

    def get_access_token
      return @access_token
    end


    ### API CALLS ###

    #uploads record data to endpoint
    def upload_to_ehr(args)
      session_id = args[:patient].identifier
      patient_id = args[:patient].id
      pdf_file_path = args[:pdf_file_path]
      sound_file_path = args[:sound_file_path]
      recording_meta_data = args[:recording_meta_data]
      request = args[:request]

      headers = get_request_headers
      pdf_file = File.new(pdf_file_path)
      sound_file = File.new(sound_file_path)

      params = {
          :recordingMetadata => recording_meta_data,
          :audio => sound_file,
          :sessionId => session_id,
          :patientId => patient_id,
          :pdf => pdf_file
      }
      if request == "put"
        response = pdf_upload_request('put', params, headers)
      else
        response = pdf_upload_request('post', params, headers)
      end
      return response
    end

    private

    def pdf_upload_request(request, params, headers, document_id="")
      url = get_request_url("api/sessions/" + params[:sessionId] + "/eko")
      if request == 'put'
        response = HTTMultiParty.put(url, :query => params, :headers => headers)
      else
        response = HTTMultiParty.post(url, :query => params, :headers => headers)
      end
      return response
    end
  end

  class MiExpressCareAPI < BaseEHR
    attr_reader :access_token, :uri

    ### API SPECIFIC HOUSEKEEPING ###

    def initialize(args={})
      params = {
        :access_token => ''
      }
      params = params.merge(args)
      if (params[:access_token] == '' || params[:access_token] == nil)
        raise ArgumentError, "Access Token='#{params[:access_token]}' is blank or nil"
      end
      @access_token = params[:access_token]
      @uri = URI.parse(params[:base_url])
    end

    def get_request_headers
      return { 'X-Auth-Token' => "#{@access_token}"}
    end

    def get_request_url(endpoint)
      return "#{@uri}/#{endpoint}"
    end

    def get_access_token
      return @access_token
    end


    ### API CALLS ###

    #uploads record data to endpoint
    def upload_to_ehr(args)
      session_id = args[:patient].identifier
      patient_id = args[:patient].id
      pdf_file_path = args[:pdf_file_path]
      sound_file_path = args[:sound_file_path]
      recording_meta_data = args[:recording_meta_data]
      request = args[:request]

      headers = get_request_headers
      pdf_file = File.new(pdf_file_path)
      sound_file = File.new(sound_file_path)

      params = {
          :recordingMetadata => recording_meta_data,
          :audio => sound_file,
          :sessionId => session_id,
          :patientId => patient_id,
          :pdf => pdf_file
      }
      if request == "put"
        response = pdf_upload_request('put', params, headers)
      else
        response = pdf_upload_request('post', params, headers)
      end
      return response
    end

    private

    def pdf_upload_request(request, params, headers, document_id="")
      url = get_request_url("upload")
      if request == 'put'
        response = HTTMultiParty.put(url, :query => params, :headers => headers)
      else
        response = HTTMultiParty.post(url, :query => params, :headers => headers)
      end
      return response
    end
  end


  class DrChronoAPI < BaseEHR
    attr_reader :access_token, :refresh_token

    ### API SPECIFIC HOUSEKEEPING ###

    def initialize(args={})
      params = {:access_code => '',
                :access_token => '',
                :refresh_token => '',
                :client_id => '',
                :client_secret => '',
                :redirect_uri => ''
              }
      params = params.merge(args)
      if (params[:access_code] == '' && (params[:access_token] == '' || params[:refresh_token] == ''))
        raise ArgumentError, "Access Code='#{params[:access_code]}' is blank or one or more of Access Token='#{params[:access_token]}', Refresh Token='#{params[:refresh_token]}' is blank"
      end
      @access_code = params[:access_code]
      @client_id = params[:client_id]
      @client_secret = params[:client_secret]
      @redirect_uri = params[:redirect_uri]
      @access_token = params[:access_token]
      @refresh_token = params[:refresh_token]
      @uri = URI.parse("https://drchrono.com")
      exchange_token
    end

    def get_request_headers
      return { 'Authorization' => "Bearer #{@access_token}"}
    end

    def get_request_url(endpoint)
      return "#{@uri}/#{endpoint}"
    end

    def get_access_token
      return @access_token
    end

    def get_refresh_token
      return @refresh_token
    end


    ### API CALLS ###

    # Not efficient
    # Get the patient using patient id from our database
    def get_patient(patient_id)
      patients = get_patients
      status = patients["status"]
      if status["error"]
        status["error_at_request"] = patients["error_at_request"]
      end
      patients = patients["results"]
      for patient in patients
        if patient["id"] == patient_id
          return patient
        end
      end
      return status
    end

    def get_patients(params={})
      patient_url = 'api/patients'
      return chrono_request(patient_url, params)
    end

    def get_changed_patients(date)
      if self.class != SuperEHR::DrChronoAPI
        date = date.gsub(/\//, '-')
        date = Date.strptime(date, '%m-%d-%Y').ios8601
      end
      return get_patients({"since" => date})
    end

    def get_changed_patients_ids(ts)
      patients = get_changed_patients(ts)
      ids = []
      for patient in patients
        ids << patient["id"]
      end
      return ids
    end

    #Since it uses get_patient this function is very ineffecient
    def get_scheduled_patients(day='')
      url = 'api/appointments'
      patients = []
      appointments = chrono_request(url, {:date => day.gsub(/\//, '-')})
      for appointment in appointments
        #gives the relative url for the patient behind the api/patients namespace, we can then use Brian's existing http helpers
        patient_url = appointment["patient"]
        patient_id = patient_url[34..-1].to_i
        patients << get_patient(patient_id)
      end
      return patients
    end

    #uploads a pdf of to dr chrono
    def upload_document(patient_id, pdf_location, description, request, document_id="", api_version = :v4)
      chrono_user_data_response = chrono_request("/api/users")
      if chrono_user_data_response["status"] && chrono_user_data_response["status"]["error"]
        return chrono_user_data_response
      else
        doctor_id = chrono_user_data_response["results"][0]["doctor"]
        headers = get_request_headers
        date = Date.today
        file = File.new(pdf_location)
        params = {
            :doctor => api_version == :v4 ? doctor_id : /\/api\/doctors\/.*/.match(doctor_id),
            :patient => api_version == :v4 ? patient_id : "/api/patients/#{patient_id}",
            :description => description,
            :date => date,
            :document => file
        }
        if request == "post"
          response = pdf_upload_request('post', params, headers)
        else
          response = pdf_upload_request('put', params, headers, document_id)
        end
        # for backwards compatibility with v1, intended to be removed along with the api_version parameter in the method upload_document and the params check for api_version after successful migration
        patient_response = response.parsed_response["patient"]
        if response.code == 400 && patient_response == ["Invalid hyperlink - No URL match."]
          upload_document(patient_id, pdf_location, description, request, document_id, :v1)
        end
        return response
      end
    end

    def chrono_request(endpoint, params={})
      return_hash = {
        "results" => []
      }
      since = params["since"]
      while endpoint
        if !endpoint.index("page_size").nil?
          params.delete("page_size")
        else
          params["page_size"] = 250
        end
        if since && !endpoint.index("since").nil?
          params.delete("since")
        elsif since
          params["since"] = since
        end
        Delayed::Worker.logger.info "I, [#{Time.zone.now.iso8601} #1] CHRONO_REQUEST -- : #{Time.zone.now.iso8601} [Worker(delayed_job host:ip-00-0-00-000 pid:1)] Make GET Request for endpoint #{endpoint} and params #{params.inspect} and headers #{get_request_headers}"
        data = make_request("GET", endpoint, params)
        api_throttled = data["detail"] && data["detail"].include?("Request was throttled")
        if data["results"]
          return_hash["results"] = return_hash["results"] | data["results"]
          return_hash["status"] = {"success" => "Complete sync"}
          if endpoint == "/api/users"
            endpoint = nil
          else
            endpoint = data["next"]
            if endpoint
              endpoint = endpoint[20..-1]
            end
          end
        elsif api_throttled
          return_hash["status"] = {"error" => data["detail"]}
          return_hash["error_at_request"] = {"endpoint" => endpoint, "params" => params}
          endpoint = nil
        else
          Delayed::Worker.logger.info "I, [#{Time.zone.now.iso8601} #1] CHRONO_REQUEST -- : #{Time.zone.now.iso8601} [Worker(delayed_job host:ip-00-0-00-000 pid:1)] Neither throttled nor results found    , #{data.inspect}"
        end
      end
      return return_hash
    end


    private

    #Checks if there is a document with description for a given patient, if there is
    def check_document(patient_id, description)
      url = "api/documents"
      params = {:patient => patient_id}

      patient_documents = chrono_request(url, params)
      for document in patient_documents
        if document["description"] == description
          return document
        end
      end
      return nil
    end

    #handles the request to dr crhono
    def pdf_upload_request(request, params, headers, document_id="")
      url = get_request_url("api/documents")
      if request == 'post'
        Delayed::Worker.logger.info "I, [#{Time.zone.now.iso8601} #1] CHRONO_REQUEST -- : #{Time.zone.now.iso8601} [Worker(delayed_job host:ip-00-0-00-000 pid:1)] Make PDF POST Request for endpoint #{url} and params #{params.inspect} and headers #{headers.inspect}"
        response = HTTMultiParty.post(url, :query => params, :headers => headers)
        return response
      else
        put_url = url + "/#{document_id}"
        Delayed::Worker.logger.info "I, [#{Time.zone.now.iso8601} #1] CHRONO_REQUEST -- : #{Time.zone.now.iso8601} [Worker(delayed_job host:ip-00-0-00-000 pid:1)] Make PDF PUT Request for endpoint #{put_url} and params #{params.inspect} and headers #{headers.inspect}"
        response = HTTMultiParty.put(put_url, :query => params, :headers => headers)
        return response
      end
    end


    def exchange_token
      if @refresh_token == '' || @refresh_token == nil
        post_args = {
          "code" => @access_code,
          "grant_type" => "authorization_code",
          "redirect_uri" => @redirect_uri,
          "client_id" => @client_id,
          "client_secret" => @client_secret
        }
        Delayed::Worker.logger.info "I, [#{Time.zone.now.iso8601} #1] CHRONO_REQUEST -- : #{Time.zone.now.iso8601} [Worker(delayed_job host:ip-00-0-00-000 pid:1)] Refresh Token When None Present"
        response = HTTParty.post(get_request_url("o/token/"),
                                 :body => post_args)
        @refresh_token = response["refresh_token"]
        @access_token = response["access_token"]
        return response["access_token"]
      else
        post_args = {
          "refresh_token" => @refresh_token,
          "grant_type" => "refresh_token",
          "redirect_uri" => @redirect_uri,
          "client_id" => @client_id,
          "client_secret" => @client_secret
        }
        Delayed::Worker.logger.info "I, [#{Time.zone.now.iso8601} #1] CHRONO_REQUEST -- : #{Time.zone.now.iso8601} [Worker(delayed_job host:ip-00-0-00-000 pid:1)] Refresh Token When Refresh Token Present"
        response = HTTParty.post(get_request_url("o/token/"),
                                 :body => post_args)
        @refresh_token = response["refresh_token"]
        @access_token = response["access_token"]
        return response["access_token"]
      end
    end
  end

  def self.allscripts(ehr_username, ehr_password, app_username, app_password, app_name, using_touchworks)
    return AllScriptsAPI.new(ehr_username, ehr_password,app_username, app_password, app_name, using_touchworks)
  end

  def self.athena(version, key, secret, practice_id)
    return AthenaAPI.new(version, key, secret, practice_id)
  end

  def self.drchrono(access_code, client_id, client_secret, redirect_uri)
    return DrChronoAPI.new({:access_code => access_code, :client_id => client_id, :client_secret => client_secret, :redirect_uri => redirect_uri})
  end

  def self.drchrono_b(access_token, refresh_token, client_id, client_secret, redirect_uri)
    return DrChronoAPI.new({:access_token => access_token, :refresh_token => refresh_token, :client_id => client_id, :client_secret => client_secret, :redirect_uri => redirect_uri})
  end

  def self.mi_express_care(args)
    return MiExpressCareAPI.new(args)
  end

  def self.call_nine(args)
    return CallNineAPI.new(args)
  end

  def self.e_clinical_works(args)
    return EClinicalWorksAPI.new(args)
  end

  def self.e_clinical_works_sales(args)
    return EClinicalWorksSalesAPI.new(args)
  end

  def self.life_letters(args)
    return LifeLettersAPI.new(args)
  end

  def self.doc_24_seven(args)
    return Doc24Seven.new(args)
  end
end
