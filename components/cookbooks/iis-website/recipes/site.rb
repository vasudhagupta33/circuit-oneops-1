site = node['iis-website']
platform_name = node.workorder.box.ciName
site_id = node.workorder.box.ciId

runtime_version = site.runtime_version
identity_type = site.identity_type

binding_type = site.binding_type
binding_port = site.binding_port
physical_path = "#{site.physical_path}/#{site.package_name}/#{node['workorder']['rfcCi']['ciAttributes']['package_version']}"

log_directory_path = site.log_file_directory
sc_directory_path = site.sc_file_directory
dc_directory_path = site.dc_file_directory

site_bindings = [{ 'protocol' => binding_type,
                   'binding_information' => "*:#{binding_port}:" }]

powershell_script "Allow Port #{binding_port}" do
  code "netsh advfirewall firewall add rule name=\"Allow port #{binding_port}\" dir=in action=allow protocol=TCP localport=#{binding_port}"
end

website_physical_path = physical_path
heartbeat_path = "#{physical_path}/heartbeat.html"

ssl_certificate_exists = false

if site.enable_certificate == 'true'
  ssl_certificate_exists = true

  if site.auto_provision == 'true'
    cloud_name = node[:workorder][:cloud][:ciName]
    provider = ""

    cert_service = node[:workorder][:services][:certificate]

    Chef::Log.info "Certificate Service - #{cloud_name} and  #{cert_service}"

    if !cert_service.nil? && !cert_service[cloud_name].nil?
    	  provider = node[:workorder][:services][:certificate][cloud_name][:ciClassName].gsub("cloud.service.","").downcase.split(".").last
    else
            Chef::Log.error("Certificate cloud service not defined for this cloud")
            exit 1
    end

    certificate = Hash.new
    certificate["common_name"] = site.common_name
    certificate["san"] = ""
    certificate["external"] = "false"
    certificate["domain"] = site.domain
    certificate["owner_email"] = site.owner_email
    certificate["passphrase"] = site.passphrase

    node.set[:certificate] = certificate
    include_recipe provider + "::add_certificate"

    ssl_data = node[:pfx_cert]
    ssl_password = site.passphrase

  else
    ssl_data = site.ssl_data
    ssl_password = site.ssl_password

  end

    cert = OpenSSL::X509::Certificate.new(ssl_data)
    thumbprint = OpenSSL::Digest::SHA1.new(cert.to_der).to_s

    iis_certificate platform_name do
      raw_data ssl_data
      password ssl_password
  end

end



=begin

certs = node.workorder.payLoad.DependsOn.select { |d| d[:ciClassName] =~ /Certificate/ }
ssl_certificate_exists = false
thumbprint = ''

certs.each do |cert|
  if !cert[:ciAttributes][:pfx_enable].nil? && cert[:ciAttributes][:pfx_enable] == 'true'
    ssl_data = cert[:ciAttributes][:ssl_data]
    ssl_password = cert[:ciAttributes][:ssl_password]
    ssl_certificate_exists = true

    cert = OpenSSL::X509::Certificate.new(ssl_data)
    thumbprint = OpenSSL::Digest::SHA1.new(cert.to_der).to_s

    iis_certificate platform_name do
      raw_data ssl_data
      password ssl_password
    end

  end
end

=end

%W( #{physical_path} #{sc_directory_path} #{dc_directory_path} #{log_directory_path}).each do | path |
  directory path do
    recursive true
  end
end

dotnetcore = node.workorder.rfcCi.ciAttributes

dotnetcore_selected = (dotnetcore.install_dotnetcore == "true" && dotnetcore.dotnet_core_package_name == "dotnetcore-windowshosting")
runtime_version = "" if (dotnetcore_selected || (runtime_version == "NoManagedCode"))


iis_app_pool platform_name do
  managed_runtime_version runtime_version
  process_model_identity_type identity_type
  recycling_log_event_on_recycle ["Time", "Requests", "Schedule", "Memory", "IsapiUnhealthy", "OnDemand", "ConfigChange", "PrivateMemory"]
  process_model_user_name site.process_model_user_name if identity_type == 'SpecificUser'
  process_model_password site.process_model_password if identity_type == 'SpecificUser'
  action [:create, :update]
end

iis_web_site platform_name do
  id site_id
  bindings site_bindings
  virtual_directory_physical_path website_physical_path.tr('/', '\\')
  application_pool platform_name
  certificate_hash thumbprint if ssl_certificate_exists
  action [:create, :update]
end

template heartbeat_path do
  source 'heartbeat.erb'
  cookbook 'iis-website'
  mode '0755'
end

iis_windows_authentication 'enabling windows authentication' do
  site_name platform_name
  enabled site.windows_authentication.to_bool
end

iis_anonymous_authentication 'anonymous authentication' do
  site_name platform_name
  enabled site.anonymous_authentication.to_bool
end

static_mime_types = JSON.parse(site.static_mime_types)

static_mime_types.each do | file_extension, mime_type |
  iis_mime_mapping 'adding mime type' do
    site_name platform_name
    file_extension file_extension
    mime_type mime_type
  end
end

include_recipe 'iis::disable_ssl'
include_recipe 'iis::enable_tls'
include_recipe 'iis::disable_weak_ciphers'

iis_log_location 'setting log location' do
  central_w3c_log_file_directory log_directory_path
  central_binary_log_file_directory log_directory_path
end

iis_urlcompression 'configure url compression and parameters' do
  static_compression site.enable_static_compression.to_bool
  dynamic_compression site.enable_dynamic_compression.to_bool
  dynamic_compression_before_cache site.url_compression_dc_before_cache.to_bool
end


iis_compression 'configure compression parameters' do
  max_disk_usage site.compression_max_disk_usage.to_i
  min_file_size_to_compress site.compresion_min_file_size.to_i
  directory sc_directory_path
  only_if { site.enable_static_compression.to_bool }
end

iis_staticcompression 'configure static compression paramters' do
  level site.sc_level.to_i
  mime_types site.sc_mime_types.to_h
  cpu_usage_to_disable site.sc_cpu_usage_to_disable.to_i
  cpu_usage_to_reenable site.sc_cpu_usage_to_reenable.to_i
  directory sc_directory_path
  only_if { site.enable_static_compression.to_bool }
end

iis_dynamiccompression 'configure dynamic compression paramters' do
  level site.dc_level.to_i
  mime_types site.dc_mime_types.to_h
  cpu_usage_to_disable site.dc_cpu_usage_to_disable.to_i
  cpu_usage_to_reenable site.dc_cpu_usage_to_reenable.to_i
  directory dc_directory_path
  only_if { site.enable_dynamic_compression.to_bool }
end

iis_requestfiltering 'configure request filter parameters' do
  allow_double_escaping site.requestfiltering_allow_double_escaping.to_bool
  allow_high_bit_characters site.requestfiltering_allow_high_bit_characters.to_bool
  verbs site.requestfiltering_verbs.to_h
  max_allowed_content_length site.requestfiltering_max_allowed_content_length.to_i
  max_url site.requestfiltering_max_url.to_i
  max_query_string site.requestfiltering_max_query_string.to_i
  file_extension_allow_unlisted site.requestfiltering_file_extension_allow_unlisted.to_bool
end

iis_isapicgirestriction 'configure isapi cgi restriction' do
  not_listed_isapis_allowed false
  not_listed_cgis_allowed false
end

iis_sessionstate 'configure session state parameters' do
  site_name platform_name
  cookieless site.session_state_cookieless
  cookiename site.session_state_cookie_name
  time_out site.session_time_out.to_i
end

iis_logging 'configure logging parameters' do
  site_name     platform_name
  logFormat     site.logformat
  directory     log_directory_path
  enabled       site.enabled.to_bool
  period        site.period
  logTargetW3C  site.logtargetw3c.to_i
end

include_recipe "iis-website::add_user_iis_iusrs"
include_recipe "iis-website::iis_logs_clean_up_task"
include_recipe "iis-website::install_dotnet_platform"
