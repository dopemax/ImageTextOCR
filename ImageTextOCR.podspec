#
# Be sure to run `pod lib lint ImageTextOCR.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'ImageTextOCR'
  s.version          = '0.0.1'
  s.summary          = 'A Swift implemented library for ImageTextOCR.'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
  A lightweight and pure Swift implemented library for ImageTextOCR.
  
  
                       DESC

  s.homepage         = 'https://github.com/dopemax/ImageTextOCR'
  # s.screenshots     = 'www.example.com/screenshots_1', 'www.example.com/screenshots_2'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'dopemax' => '1003990034@qq.com' }
  s.source           = { :git => 'git@github.com:dopemax/ImageTextOCR.git', :tag => s.version.to_s }
  # s.social_media_url = 'https://twitter.com/<TWITTER_USERNAME>'

  s.swift_versions = ['5.0']

  s.ios.deployment_target = "15.0"

  s.source_files = 'ImageTextOCR/Classes/**/*'
  
  # s.resource_bundles = {
  #   'ImageTextOCR' => ['ImageTextOCR/Assets/*.png']
  # }

  # s.public_header_files = 'Pod/Classes/**/*.h'
  # s.frameworks = 'UIKit', 'MapKit'
#  s.frameworks = "Network"
  s.dependency 'Alamofire'
  
end
