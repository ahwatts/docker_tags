#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'
require 'uri'

require 'rubygems'
require 'semverse'

REGISTRY_BASE_URL = 'https://registry.hub.docker.com/v2'

module Hub
  Tag = Struct.new(:name, :last_updated, :status, :images) do
    def self.from_json(tag_json)
      tag = new(
        tag_json['name'],
        tag_json['last_updated'] ? Time.iso8601(tag_json['last_updated']) : Time.at(0),
        tag_json['tag_status'],
        []
      )
      tag.images = tag_json['images'].map { |i| Image.from_json(i, tag) }
      tag
    end
  end

  Image = Struct.new(
    :architecture, :features, :variant, :os, :os_features, :os_version, :digest, :status,
    :last_updated, :tag
  ) do
    def self.from_json(image_json, tag)
      new(
        image_json['architecture'],
        image_json['features'],
        image_json['variant'],
        image_json['os'],
        image_json['os_features'],
        image_json['os_version'],
        image_json['digest'],
        image_json['status'],
        image_json['last_pushed'] ? Time.iso8601(image_json['last_pushed']) : Time.at(0),
        tag
      )
    end

    def platform
      @platform ||= Script::Platform.new(
        architecture,
        features,
        variant,
        os,
        os_features,
        os_version
      )
    end
  end
end

module Script
  Platform = Struct.new(:architecture, :features, :variant, :os, :os_features, :os_version)

  class Tag
    attr_reader :name, :version

    def initialize(tag_name)
      @name = tag_name
      begin
        @version = Semverse::Version.new(tag_name)
      rescue
        @version = nil
      end
    end

    def <=>(other)
      if other.nil?
        1
      elsif version.nil? || other.version.nil?
        name <=> other.name
      else
        [version, name] <=> [other.version, other.name]
      end
    end

    def eql?(other)
      name == other.name
    end
  end

  class Image
    attr_reader :platform, :tags, :digest, :last_updated, :status, :dominant_version

    def initialize(hub_image)
      @platform = hub_image.platform
      @tags = [Script::Tag.new(hub_image.tag.name)]
      @dominant_version = @tags.first
      @digest = hub_image.digest
      @last_updated = [hub_image.tag.last_updated, hub_image.last_updated].max

      @tag_obj = hub_image.tag
      @img_objs = [hub_image]
    end

    def add_image!(hub_image)
      raise ArgumentError, 'Cannot add image with a different digest' if hub_image.digest != digest
      raise ArgumentError, 'Cannot add image with a different platform' if hub_image.platform != platform

      @tags << Script::Tag.new(hub_image.tag.name)
      @tags.uniq!
      sort_tags!
      @last_updated = [@last_updated, hub_image.last_updated].max
      @img_objs << hub_image
    end

    def <=>(other)
      if other.nil?
        1
      elsif dominant_version.nil? && other.dominant_version.nil?
        last_updated <=> other.last_updated
      elsif dominant_version.nil? # && !other.dominant_version.nil?
        -1
      elsif other.dominant_version.nil? # && dominant_version.nil?
        1
      else
        [dominant_version, last_updated] <=> [other.dominant_version, other.last_updated]
      end
    end

    private

    def sort_tags!
      versioned_tags = sort_versioned_tags
      unversioned_tags = @tags - versioned_tags
      @tags = versioned_tags + unversioned_tags.sort_by(&:name)
      @dominant_version = @tags.first
    end

    def sort_versioned_tags
      with_sat_counts = []
      @tags.each do |tag|
        next if tag.version.nil?

        c = begin
          Semverse::Constraint.new("~> #{tag.name}")
        rescue
          next
        end

        sat_count = 0
        @tags.each do |tag2|
          next if tag2.version.nil?

          sat_count += 1 if c.satisfies?(tag2.version)
        end
        with_sat_counts << [tag, sat_count]
      end
      with_sat_counts.sort_by { |(v, c)| [c, -v.name.size] }.map(&:first)
    end
  end
end

repository = ARGV.shift
repository = "library/#{repository}" unless repository.include?('/')
path = "/repositories/#{repository}/tags?page_size=100"
url = URI("#{REGISTRY_BASE_URL}#{path}")

tags = []
loop do
  break if url.nil?

  # warn("Getting #{url}...")
  response_str = Net::HTTP.get(url)
  tags_json = JSON.parse(response_str)
  tags += tags_json['results'].map { |t| Hub::Tag.from_json(t) }
  url = tags_json['next'] && URI(tags_json['next'])
end

by_arch = {}
tags.each do |t|
  t.images.each do |i|
    by_arch[i.platform] ||= []
    by_arch[i.platform] << i
  end
end

script_images = Hash[
  by_arch.map do |arch, hub_images|
    by_digest = {}
    hub_images.each do |hub_image|
      if by_digest[hub_image.digest].nil?
        by_digest[hub_image.digest] = Script::Image.new(hub_image)
      else
        by_digest[hub_image.digest].add_image!(hub_image)
      end
    end
    [arch, by_digest]
  end
]

script_images.each do |arch, by_digest|
  next unless arch.architecture == 'amd64'

  by_digest.sort_by(&:last).reverse.each do |_digest, image|
    tag_names = image.tags.map(&:name).join(', ')
    puts("#{image.last_updated}\t#{tag_names}")
  end
end
