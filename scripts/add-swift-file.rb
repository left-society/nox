#!/usr/bin/env ruby
# add-swift-file.rb — register a new Swift file in Notetaker.xcodeproj
#
# Why this exists: hand-editing project.pbxproj is error-prone. Each new
# .swift file needs four edits (PBXBuildFile entry, PBXFileReference
# entry, PBXGroup membership, PBXSourcesBuildPhase listing) plus matching
# 24-char ID generation. The xcodeproj Ruby gem handles all of that —
# this wrapper keeps the invocation one-line.
#
# Usage:
#   ./scripts/add-swift-file.rb \
#       --file Notetaker/NotchPill/PillContextMenu.swift \
#       --group NotchPill \
#       [--test]      # add to NotetakerTests target instead of main app
#
# The --group flag matches the existing top-level group name inside the
# Notetaker source root (NotchPill, Services, Panel, Settings, App,
# DesignSystem, Resources). It must already exist.
#
# Idempotent: re-running with the same file is a no-op (skips duplicate
# file references and build-phase entries).

require 'xcodeproj'
require 'optparse'

opts = { test: false }
OptionParser.new do |o|
  o.on('--file PATH') { |v| opts[:file] = v }
  o.on('--group NAME') { |v| opts[:group] = v }
  o.on('--test') { opts[:test] = true }
end.parse!

abort 'usage: add-swift-file.rb --file <path> --group <group> [--test]' \
  unless opts[:file] && opts[:group]

project_path = File.expand_path('../../Notetaker.xcodeproj', __FILE__)
project = Xcodeproj::Project.open(project_path)

# Find the target — main app or test target
target_name = opts[:test] ? 'NotetakerTests' : 'Notetaker'
target = project.targets.find { |t| t.name == target_name }
abort "No target named '#{target_name}' in project" unless target

# Find the source root group, then the named subgroup
source_root = project.main_group.find_subpath('Notetaker', false)
source_root ||= project.main_group  # fallback for older project layouts
group = source_root.find_subpath(opts[:group], false) ||
        source_root.groups.find { |g| g.name == opts[:group] || g.path == opts[:group] }

if group.nil?
  # Last resort — create the group at source root
  group = source_root.new_group(opts[:group], opts[:group])
  puts "Created new group '#{opts[:group]}' under Notetaker source root"
end

# Skip if the file is already registered
file_basename = File.basename(opts[:file])
existing = group.files.find { |f| f.display_name == file_basename }
if existing
  puts "Already registered: #{opts[:file]} — no-op"
  exit 0
end

# Add file reference + build phase entry
file_ref = group.new_reference(file_basename)
file_ref.source_tree = '<group>'
target.add_file_references([file_ref])

project.save

puts "Registered: #{opts[:file]} -> target '#{target_name}', group '#{opts[:group]}'"
