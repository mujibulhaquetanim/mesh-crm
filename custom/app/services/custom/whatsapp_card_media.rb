require 'faraday/multipart'
require 'ipaddr'
require 'resolv'

# Turns a card's `media_url` into a WhatsApp media id: the photo is fetched
# here and uploaded to the Cloud API's media endpoint, so Meta never fetches
# it from us (its fwdproxy rate limits per hosting ASN and answers 131053;
# see Whatsapp::MediaUploadService, which does the same for attachments).
#
# ⚠ SSRF: `media_url` is message data, so every hop is checked:
# - the first URL must be https on a host in CARD_MEDIA_ALLOWED_HOSTS (comma
#   separated, exact, e.g. `api.zasmate.com`);
# - a redirect must be https to a host in that list, or to a domain in
#   CARD_MEDIA_REDIRECT_HOSTS (suffix match, e.g. `r2.cloudflarestorage.com`,
#   where the API's photo route redirects);
# - every host must resolve only to public addresses (no loopback, private,
#   link-local or unspecified ones).
# With CARD_MEDIA_ALLOWED_HOSTS unset nothing is fetched and every card goes
# without its photo.
#
# Returns { 'id' => media_id }, or nil on any problem (the card then goes
# without a header rather than not at all).
class Custom::WhatsappCardMedia
  MAX_BYTES = 5 * 1024 * 1024
  IMAGE_TYPES = %w[image/jpeg image/png].freeze
  TIMEOUT = 15
  MAX_REDIRECTS = 2

  def initialize(whatsapp_channel)
    @channel = whatsapp_channel
  end

  def media_for(url)
    return unless allowed?(url, redirect: false)

    image = fetch(url)
    image && upload(image)
  rescue StandardError => e
    Rails.logger.warn("WhatsappCardMedia: no photo for a card on inbox #{@channel.inbox&.id}: #{e.class}: #{e.message}")
    nil
  end

  private

  def allowed?(url, redirect:)
    uri = URI.parse(url.to_s)
    host = uri.host.to_s.downcase
    uri.is_a?(URI::HTTPS) && listed?(host, redirect) && public_host?(host)
  rescue URI::InvalidURIError
    false
  end

  def listed?(host, redirect)
    return true if hosts('CARD_MEDIA_ALLOWED_HOSTS').include?(host)

    redirect && hosts('CARD_MEDIA_REDIRECT_HOSTS').any? { |domain| host == domain || host.end_with?(".#{domain}") }
  end

  def hosts(variable)
    ENV.fetch(variable, '').split(',').map { |h| h.strip.downcase }.reject(&:empty?)
  end

  # Every address the host resolves to is public; nothing resolved → refused.
  def public_host?(host)
    addresses = Resolv.getaddresses(host)
    addresses.any? && addresses.none? { |address| private_address?(IPAddr.new(address)) }
  rescue IPAddr::InvalidAddressError
    false
  end

  def private_address?(ip)
    ip.loopback? || ip.private? || ip.link_local? || ip.to_s == '0.0.0.0' || ip.to_s == '::'
  end

  # { body:, type: } for a JPEG or PNG within WhatsApp's 5 MB header limit,
  # following at most MAX_REDIRECTS redirects, each of them to https.
  def fetch(url)
    (MAX_REDIRECTS + 1).times do
      response = HTTParty.get(url, follow_redirects: false, timeout: TIMEOUT)
      return image_from(response) unless redirect?(response)

      url = URI.join(url, response.headers['location']).to_s
      return unless allowed?(url, redirect: true)
    end
    nil
  end

  def redirect?(response)
    response.code.between?(300, 399) && response.headers['location'].present?
  end

  def image_from(response)
    return unless response.code == 200

    type = response.headers['content-type'].to_s.split(';').first.to_s.strip.downcase
    body = response.body.to_s
    return unless IMAGE_TYPES.include?(type) && body.bytesize.positive? && body.bytesize <= MAX_BYTES

    { body: body, type: type }
  end

  def upload(image)
    extension = image[:type] == 'image/png' ? 'png' : 'jpg'
    response = connection.post(upload_url) do |request|
      request.headers['Authorization'] = "Bearer #{@channel.provider_config['api_key']}"
      request.body = {
        messaging_product: 'whatsapp',
        type: image[:type],
        file: Faraday::Multipart::FilePart.new(StringIO.new(image[:body]), image[:type], "card.#{extension}")
      }
    end
    media_id = response.body['id'] if response.body.is_a?(Hash)
    { 'id' => media_id } if response.success? && media_id.present?
  end

  def connection
    @connection ||= Faraday.new do |f|
      f.request :multipart
      f.response :json
      f.options.timeout = 60
      f.options.open_timeout = TIMEOUT
    end
  end

  def upload_url
    base_path = ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
    version = GlobalConfigService.load('WHATSAPP_API_VERSION', Whatsapp::MediaUploadService::WHATSAPP_API_VERSION_FALLBACK)
    "#{base_path}/#{version}/#{@channel.provider_config['phone_number_id']}/media"
  end
end
