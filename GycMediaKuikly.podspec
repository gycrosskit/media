Pod::Spec.new do |spec|
  spec.name = 'GycMediaKuikly'
  spec.version = '0.1.9'
  spec.summary = 'GY CrossKit media Kuikly native receiver.'
  spec.homepage = 'https://github.com/gycrosskit/media'
  spec.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  spec.author = { 'gycrosskit' => 'guoyanggit@gmail.com' }
  spec.source = { :git => 'https://github.com/gycrosskit/media.git', :tag => spec.version.to_s }
  spec.ios.deployment_target = '14.0'
  spec.swift_version = '5.9'
  spec.default_subspec = 'Kuikly'
  spec.subspec 'Kuikly' do |kuikly|
    kuikly.source_files = 'iosApp/Sources/GycMediaKuikly/*.swift'
    kuikly.dependency 'OpenKuiklyIOSRender', '2.28.0'
  end
end
