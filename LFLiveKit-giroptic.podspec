
Pod::Spec.new do |s|

  s.name         = "LFLiveKit-giroptic"
  s.version      = "2.6.2"
  s.summary      = "LaiFeng ios Live. LFLiveKit."
  s.homepage     = "https://github.com/giroptic"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = { "GIROPTIC" => "contact@giroptic.com", "chenliming" => "chenliming777@qq.com" }
  s.platform     = :ios, "7.0"
  s.ios.deployment_target = "7.0"
  s.source       = { :git => "https://github.com/umxprime/LFLiveKit.git", :tag => "#{s.version}" }
  s.source_files  = "LFLiveKit/**/*.{h,m,mm,cpp,c}"
  s.public_header_files = ['LFLiveKit/*.h', 'LFLiveKit/objects/*.h', 'LFLiveKit/configuration/*.h']

  s.frameworks = "VideoToolbox", "AudioToolbox","AVFoundation","Foundation","UIKit"
  s.libraries = "c++", "z"

  s.requires_arc = true
end