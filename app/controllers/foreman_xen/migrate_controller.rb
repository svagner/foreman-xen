module ForemanXen
  class MirgateController < ::ApplicationController
    helper :all
    skip_before_filter  :verify_authenticity_token

    #GET - foreman_xen/migrate/:host_id
    def show
      process_error({:error_msg => "Test message."})
    end

    def migrate_url
      case params[:action]
        when 'show'
          return '/'
      end
    end

  end
end