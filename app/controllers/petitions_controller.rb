class PetitionsController < ApplicationController
  include Carmen

  before_filter :require_login, except: [:show, :again]
  before_filter :track_visit, only: :show
  before_filter :require_admin, only: :index

  def index
    @petitions = Petition.order('created_at DESC').limit(50)
  end

  def show
    @petition = Petition.find(params[:id])
    @sigcount = @petition.sigcount

    @referring_url = request.original_url

    @referer_ref_type, @referer_ref_code = SignatureReferral.translate_raw_referral(params)

    @email_hash = params[:n]

    @member = member_from_cookies || member_from_email
    @was_signed = member_from_cookies.present? && member_from_cookies.has_signed?(@petition)

    @referer_code = ReferralCode.where(code: @referer_ref_code).first if @referer_ref_code.present?

    @signer_code = if @member.present?
      @member.referral_codes.where(petition_id: @petition.id).first || @member.referral_codes.build(petition_id: @petition.id)
    else
      ReferralCode.new(petition_id: @petition.id)
    end

    @signature = flash[:invalid_signature] || @petition.signatures.build
    @signature.prepopulate(@member) if @member.present? && !@member.has_signed?(@petition)

    # TODO Remove this - this is not the right way to propagate member information to the SocialTracking controller.
    @signature.id = Signature.where(member_id: @member.try(:id), petition_id: @petition.id).first.try(:id)

    @just_signed = flash[:signature_id].present?
    @signing_from_email = sent_email.present? && !@was_signed

    @facebook_friend_ids = facebook_friends @member
    @query = request.query_parameters
    @share_count = FacebookAction.count # used in _thanks_for_signing experiment

    @petition_layout = petition_layouts
    @progress_location = progress_locations
  end

  def petition_layouts
    spin! 'toggle layout of position page', :signature, ['classic', 'focused']
  end

  def progress_locations
    if (@petition_layout == 'classic') && !browser.mobile? && !browser.ie?
      spin! 'toggle position and rendering of progress bar', :signature, ['hide_progress', 'header_progress', 'sidebar_progress']
    end
  end

  def again
    cookies.delete :member_id
    cookies.delete :ref_code
    redirect_to petition_path(params[:id], request.query_parameters)
  end

  def new
    @states, @countries = hash_states_and_countries
    @petition = Petition.new
  end

  def edit
    @states, @countries = hash_states_and_countries
    @petition = Petition.find(params[:id])
    return render_403 unless @petition.has_edit_permissions(current_user)
  end

  def create
    compress_location params[:petition]
    @petition = Petition.new(params[:petition], as: role)
    @petition.owner = current_user
    @petition.ip_address = connecting_ip
    if @petition.save
      redirect_to @petition, notice: 'Petition was successfully created.'
    else
      @states, @countries = hash_states_and_countries
      refresh "new"
    end
  end

  def update
    @petition = Petition.find(params[:id])
    return render_403 unless @petition.has_edit_permissions(current_user)
    compress_location params[:petition]
    if @petition.update_attributes(params[:petition], as: role)
      redirect_to @petition, notice: 'Petition was successfully updated.'
    else
      @states, @countries = hash_states_and_countries
      refresh "edit"
    end
  end

  def send_email_preview
    @petition = params[:id].present? ? Petition.find(params[:id]) : Petition.new
    compress_location params[:petition]
    @petition.assign_attributes(params[:petition], as: role)
    current_member = Member.find_or_initialize_by_email(email: current_user.email, first_name: "Admin", last_name: "User")
    ScheduledEmail.send_preview @petition, current_member
    respond_to do |format|
      format.json  { render :json => ['success'].to_json }
    end
  end

  private

  def hash_states_and_countries
    us = Country.coded 'US'
    rest = Country.all - [us]
    [us.subregions, rest].map do |a|
      Hash[a.index_by(&:code).map{|k, v| [k, v.name]}.sort_by{|k, v| v}]
    end
  end

  def compress_location params
    return unless params
    return unless t = params[:location_type]
    d = params[:location_details]
    params[:location] = d.blank? ? t : d.split(',').map{|e| "#{t}/#{e}"}.join(',')
    params.delete :location_type
    params.delete :location_details
  end

  def refresh action
    flash[:error] = @petition.errors.full_messages.to_sentence if @petition.errors.any?
    render action: action
  end

  def sent_email
    SentEmail.find_by_hash(params[:n])
  end
  memoize :sent_email

  def member_from_cookies
    Member.find_by_hash(cookies[:member_id])
  end
  memoize :member_from_cookies

  def member_from_email
    sent_email.try(:member)
  end
  memoize :member_from_email

  def facebook_friends member
    fb_friends = FacebookFriend.find_all_by_member_id(member.id) if member.present?
    facebook_ids = ''
    fb_friends.each { |friend| facebook_ids << "'#{friend.facebook_id}'," } if fb_friends.present?
    facebook_ids.to_s
  end

  def track_visit
    sent_email.track_visit! if sent_email.present?
  end
end
