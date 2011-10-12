# $Id$

require "rake"
require "rake/gempackagetask"
require "rake/rdoctask"
require "rake/clean"
require "spec/rake/spectask"
require "code_statistics" 

NAME = "rastman"
VERS = "0.1.6"
CLEAN.include ["pkg", "*.gem", "doc", "coverage"]
RDOC_OPTS = ["--quiet", "--title", "Rastman Documentation",
  "--opname", "index.html",
  "--line-numbers",
  "--main", "README",
  "--inline-source"]

desc "Packages up Rastman."
task :default => [:package]
task :rastman => [:clean, :rdoc, :package]
task :doc => [:rdoc]

Rake::RDocTask.new do |rdoc|
  rdoc.rdoc_dir = "doc/rdoc"
  rdoc.options += RDOC_OPTS
  rdoc.main = "README"
  rdoc.title = "Rastman Documentation"
  rdoc.rdoc_files.add ["README", "TODO", "CHANGELOG", "lib/rastman.rb"]
end

spec = Gem::Specification.new do |s|
  s.name = NAME
  s.version = VERS
  s.platform = Gem::Platform::RUBY
  s.has_rdoc = true
  s.rdoc_options += RDOC_OPTS
  s.extra_rdoc_files = ["README"]
  s.summary = "Asterisk Manager API interface for Ruby"
  s.description = s.summary
  s.author = "Mathieu Lajugie"
  s.email = "mathieul@zlaj.org"
  s.homepage = "http://rastman.rubyforge.org/"
  s.executables = ["rastman_mkcalls.rb"]
  s.required_ruby_version = ">= 1.8.4"
  s.files = %w(MIT-LICENSE README TODO CHANGELOG) + Dir.glob("{bin,lib}/**/*")
  s.require_path = "lib"
  s.bindir = "bin"
end

Rake::GemPackageTask.new(spec) do |p|
  p.gem_spec = spec
end

task :install do
  sh %{rake package}
  sh %{sudo gem install pkg/#{NAME}-#{VERS}}
end

task :uninstall => [:clean] do
  sh %{sudo gem uninstall #{NAME}}
end

desc "Run all specs"
Spec::Rake::SpecTask.new("specs") do |t|
  t.spec_opts = ["--format", "specdoc", "-c"]
  t.libs = ["lib"]
  t.spec_files = FileList["specs/**/*_spec.rb"]
end

desc "Generate HTML specs report"
Spec::Rake::SpecTask.new("html_specs") do |t|
  t.spec_opts = ["--format", "html", "-c"]
  t.spec_files = FileList["specs/**/*_spec.rb"]
  t.out = "specs_report.html"
end

desc "RCov"
Spec::Rake::SpecTask.new("rcov") do |t|
  t.spec_files = FileList["specs/**/*_spec.rb"]
  #t.spec_opts = ["--format", "specdoc", "-c"]
  t.rcov_opts = ['--exclude', 'specs\/']
  t.rcov = true
end

STATS_DIRECTORIES = [
  %w(API    lib),
  %w(Specs  specs),
  %w(Tools  bin)
].collect { |name, dir| [ name, "./#{dir}" ] }.select { |name, dir| File.directory?(dir) }

desc "Report code statistics (KLOCs, etc) from the application"
task :stats do
  #require "extra/stats"
  verbose = true
  CodeStatistics.new(*STATS_DIRECTORIES).to_s
end

#
#  Created by Mathieul on 2007-02-08.
#  Copyright (c) 2007. All rights reserved.
