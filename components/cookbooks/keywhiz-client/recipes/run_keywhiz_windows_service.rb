

raw_data = node[:pfx_cert]
password = node[:sync_cert_passphrase]
certificate_file = ::File.join('c:\windows\temp', "keysync_cert.pfx")

key = OpenSSL::PKey.read(raw_data, password)
cert = OpenSSL::X509::Certificate.new(raw_data)
pkcs12 = OpenSSL::PKCS12.create(password, 'keysync_cert', key, cert)

::File.open(certificate_file, 'wb'){|f| f << pkcs12.to_der }
thumbprint = OpenSSL::Digest::SHA1.new(cert.to_der).to_s

powershell_script 'Import pfx certificate' do
  code "certutil.exe -p #{password} -importpfx #{certificate_file}"
  guard_interpreter :powershell_script
  not_if "if (Get-ChildItem -Path Cert:\\LocalMachine\\My | Where-Object {$_.Thumbprint -eq '#{thumbprint}'}) { $true } else { $false }"
end


#Start Keywhiz Windows Service
if node[:workorder][:services].has_key?('secret')

  cloud = node.workorder.cloud.ciName
  chocolatey_package_details = JSON.parse(node[:workorder][:services][:secret][cloud]['ciAttributes']['keywhiz_chocopackage_details'])
  chocolatey_package_source = node[:workorder][:services][:secret][cloud]['ciAttributes']['keywhiz_chocopackage_source_url']

  mirror_svc = node[:workorder][:services][:mirror]
  if !mirror_svc.nil?
    mirror = JSON.parse(mirror_svc[cloud][:ciAttributes][:mirrors])
    mirror_pkg_source_url = mirror['chocorepo']
  end

  mirror_url_nil_or_empty = mirror_pkg_source_url.nil? || mirror_pkg_source_url.empty?
  package_source_url = mirror_url_nil_or_empty ? chocolatey_package_source : mirror_pkg_source_url

  username = node.workorder.rfcCi.ciAttributes.user
  password = node.workorder.rfcCi.ciAttributes.password

  node.set['workorder']['rfcCi']['ciAttributes']['user_right'] = "SeServiceLogonRight"
  include_recipe 'windows-utils::assign_user_rights'

  params = "\"/Username:\"#{username}\" /Password:\"#{password}\"\""

  Chef::Log.info("Using chocolatey repo #{package_source_url}")

  chocolatey_package_details.each do |package_name, package_version|
    Chef::Log.info("installing #{package_name}")
    chocolatey_package package_name do
      source package_source_url
      options "--ignore-package-exit-codes=3010 --package-parameters #{params}"
      version package_version
      action :install
    end
  end

else
  Chef::Log.error("Cloud does not contain Keywhiz Cloud Service !!")
end
