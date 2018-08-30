# frozen_string_literal: true

require 'active_support/core_ext/hash/indifferent_access'
require 'date'
require 'esi-client-bvv'
require 'esi-utils-bvv'
require 'oauth2'
require 'set'
require 'slack-notifier'
require 'yaml'
require 'yaml/store'

#
# Load the configuration file named on the command line,
# or 'config.yaml' by default.
#
config = YAML.load_file(ARGV[0] || 'config.yaml').with_indifferent_access

#
# Get an OAuth2 access token for ESI.
#

client = OAuth2::Client.new(config[:client_id], config[:client_secret],
                            site: 'https://login.eveonline.com')

# Wrap the refresh token.
refresh_token = OAuth2::AccessToken.new(client, '',
                                        refresh_token: config[:refresh_token])

# Refresh to get the access token.
access_token = refresh_token.refresh!

#
# Get the owner information for the refresh token.
#
response = access_token.get('/oauth/verify')
character_info = response.parsed
character_id = character_info['CharacterID']

#
# Configure ESI with our access token.
#
ESI.configure do |conf|
  conf.access_token = access_token.token
  conf.logger.progname = 'posbot'
  conf.logger.level = config[:log_level] || 'info'
end

my_client = ESIUtils::ESIClient.new

universe_api = ESI::UniverseApi.new(my_client)
corporation_api = ESI::CorporationApi.new(my_client)
character_api = ESI::CharacterApi.new(my_client)

#
# From the public information about the character, locate the corporation ID.
#
character = character_api.get_characters_character_id(character_id)
corporation_id = character.corporation_id

#
# Configure the number of days under which we should regard the
# fuelling state as either 'danger' or 'warning'.
#
DANGER_DAYS = config[:danger_days] || 3
WARNING_DAYS = config[:warning_days] || 7

#
# Translate the number of days left to a fuelling state.
#
def left_to_state(left)
  if left <= DANGER_DAYS
    'danger'
  elsif left <= WARNING_DAYS
    'warning'
  else
    'good'
  end
end

#
# Class representing a Player Owned Starbase.
#
class POS
  #
  # type_id for Strontium Clathrates
  #
  TYPE_ID_STRONT = 16_275

  #
  # Basic information comes from the list of POSes belonging to the corporation.
  # This includes:
  #    moon_id
  #    starbase_id
  #    state
  #    system_id
  #    type_id
  #
  attr_reader :basic
  attr_reader :detail
  attr_reader :name

  # Attributes extracted from the raw data
  attr_reader :starbase_id, :system_id, :type_id

  attr_accessor :old_state

  def initialize(basic, detail, name)
    @basic = basic
    @detail = detail
    @name = name
    @system_id = basic.system_id
    @starbase_id = basic.starbase_id
    @type_id = basic.type_id
  end

  #
  # How many blocks of fuel does this type of POS consume per hour?
  #
  # For simplicity, we're assuming this is a small POS, because that's
  # all we have to deal with in practice.
  #
  def fuel_per_hour
    10
  end

  #
  # How many blocks of fuel does this POS have in its fuel bay?
  #
  # Return the number of blocks in the fuel bay which does _not_
  # contain Strontium Clathrates.
  #
  def fuel_blocks
    bay = @detail.fuels.detect { |b| b.type_id != TYPE_ID_STRONT }
    return 0 unless bay
    bay.quantity
  end

  #
  # How many hours worth of fuel does this POS have in its fuel bay?
  #
  # Round _down_ to be on the safe side.
  #
  def fuel_hours
    (fuel_blocks / fuel_per_hour).floor
  end

  def fuel_days
    fuel_hours / 24.0
  end

  def state
    left_to_state(fuel_days)
  end
end

#
# Get the list of corporation POSes.
#
# There are two API calls involved. The first returns a list of starbases
# in a form that includes a starbase_id and a system_id along with some other
# raw data. The location information is then used to acquire detailed data.
# We combine these raw responses into a composite object for the POS, and
# extract useful fields from that.
#
poses = corporation_api.get_corporations_corporation_id_starbases(corporation_id)
poses.map! do |pos|
  # Collect the detail data for this POS
  detail = corporation_api.get_corporations_corporation_id_starbases_starbase_id(corporation_id,
                                                                                 pos.starbase_id, pos.system_id)

  # Figure out what to call the POS. The actual name doesn't seem to be
  # available, so just use the name of its moon.
  moon = universe_api.get_universe_moons_moon_id(pos.moon_id)

  POS.new(pos, detail, moon.name)
end

# Sort by name. These are moon names within a system,
# and that more or less works.
poses.sort_by!(&:name)

#
# If a list of system names has been configured, remove any POSes
# which aren't in the listed systems.
#
if config[:systems]
  # Make a set of IDs for the named systems
  systems = universe_api.post_universe_ids(config[:systems]).systems
  system_ids = Set.new(systems.map(&:id))
  # Delete POSes in systems not included in that set
  poses.delete_if do |pos|
    !system_ids.include?(pos.system_id)
  end
end

# Sort by fuel expiry time.
poses.sort_by!(&:fuel_hours)

# Initialise state store.
store = YAML::Store.new(config[:statefile])
store.transaction do
  store[:state] = {} unless store[:state]
end

# Pull the previous state for each POS out of the store
poses.each do |pos|
  store.transaction do
    pos.old_state = store[:state][pos.starbase_id] || 'unknown'
  end
end

# Remove any structures which are in the same state as last time
poses.delete_if do |pos|
  pos.state == pos.old_state
end

# Heavyweight display as used by FuelBot
# # Map each remaining structure to a Slack attachment
# attachments = poses.map do |pos|
#   eve_time = (DateTime.now + pos.fuel_days).strftime('%A, %Y-%m-%d %H:%M:%S EVE time')
#   {
#     title: pos.name,
#     color: pos.state,
#     text: "Fuel expires in #{format('%.1f', pos.fuel_days)} days.\n" \
#           "POS will go offline at #{eve_time}.\n" \
#           "Old state: #{pos.old_state}, new state: #{pos.state}",
#     fallback: "#{pos.name} fuel state is #{pos.state}.",
#     thumb_url: "https://imageserver.eveonline.com/Render/#{pos.type_id}_128.png"
#   }
# end

# Map each remaining structure to a Slack attachment
attachments = poses.map do |pos|
  eve_time = (DateTime.now + pos.fuel_days).strftime('%A, %Y-%m-%d %H:%M:%S EVE time')
  days = "#{format('%.1f', pos.fuel_days)} days"
  {
    title: "#{pos.name} is #{pos.state.upcase} (#{days})",
    color: pos.state,
    text: "POS will go offline at #{eve_time}",
    fallback: "#{pos.name} fuel state is #{pos.state}."
  }
end

# If we have any 'danger' states, take special action
panic = poses.find_index { |pos| pos.state == 'danger' }
panic_text = panic ? '<!channel> :scream:' : ''

#
# Configure Slack.
#

slack_config = config[:slack]
notifier = Slack::Notifier.new slack_config[:webhook_url] do
  defaults slack_config[:defaults]
end

#
# Send a Slack ping if we have anything to say.
#
unless attachments.empty?
  notifier.ping panic_text + 'POS fuel state changes:',
                attachments: attachments
end

#
# Write the state of these structures back for next time.
#
store.transaction do
  poses.each do |pos|
    store[:state][pos.starbase_id] = pos.state
  end
end
