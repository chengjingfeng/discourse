# frozen_string_literal: true

require 'csv'

class InvitesController < ApplicationController

  requires_login only: [:create, :retrieve, :destroy, :destroy_all_expired, :resend_invite, :resend_all_invites, :upload_csv]

  skip_before_action :check_xhr, except: [:perform_accept_invitation]
  skip_before_action :preload_json, except: [:show]
  skip_before_action :redirect_to_login_if_required

  before_action :ensure_invites_allowed, only: [:show, :perform_accept_invitation]
  before_action :ensure_new_registrations_allowed, only: [:show, :perform_accept_invitation]
  before_action :ensure_not_logged_in, only: [:show, :perform_accept_invitation]

  def show
    expires_now

    RateLimiter.new(nil, "invites-show-#{request.remote_ip}", 100, 1.minute).performed!

    invite = Invite.find_by(invite_key: params[:id])
    if invite.present? && invite.redeemable?
      email = Email.obfuscate(invite.email)

      # Show email if the user already authenticated their email
      if session[:authentication]
        auth_result = Auth::Result.from_session_data(session[:authentication], user: nil)
        if invite.email == auth_result.email
          email = invite.email
        end
      end

      hidden_email = email != invite.email

      info = {
        invited_by: UserNameSerializer.new(invite.invited_by, scope: guardian, root: false),
        email: email,
        hidden_email: hidden_email,
        username: hidden_email ? '' : UserNameSuggester.suggest(invite.email),
        is_invite_link: invite.is_invite_link?
      }

      if staged_user = User.where(staged: true).with_email(invite.email).first
        info[:user_fields] = staged_user.user_fields
      end

      store_preloaded("invite_info", MultiJson.dump(info))

      secure_session["invite-key"] = invite.invite_key

      render layout: 'application'
    else
      flash.now[:error] = if invite.blank?
        I18n.t('invite.not_found', base_url: Discourse.base_url)
      elsif invite.redeemed?
        if invite.is_invite_link?
          I18n.t('invite.not_found_template_link', site_name: SiteSetting.title, base_url: Discourse.base_url)
        else
          I18n.t('invite.not_found_template', site_name: SiteSetting.title, base_url: Discourse.base_url)
        end
      elsif invite.expired?
        I18n.t('invite.expired', base_url: Discourse.base_url)
      end

      render layout: 'no_ember'
    end
  rescue RateLimiter::LimitExceeded => e
    flash.now[:error] = e.description
    render layout: 'no_ember'
  end

  def create
    if params[:email].present? && Invite.exists?(email: params[:email])
      return render json: failed_json, status: 422
    end

    if params[:topic_id].present?
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::InvalidParameters.new(:topic_id) if topic.blank?
      guardian.ensure_can_invite_to!(topic)
    end

    if params[:group_ids].present? || params[:group_names].present?
      groups = Group.lookup_groups(group_ids: params[:group_ids], group_names: params[:group_names])
    end

    guardian.ensure_can_invite_to_forum!(groups)

    begin
      invite = Invite.generate(current_user,
        email: params[:email],
        skip_email: params[:skip_email],
        invited_by: current_user,
        custom_message: params[:custom_message],
        max_redemptions_allowed: params[:max_redemptions_allowed],
        topic_id: topic&.id,
        group_ids: groups&.map(&:id),
        expires_at: params[:expires_at],
      )

      if invite.present?
        render_serialized(invite, InviteSerializer, scope: guardian, root: nil, show_emails: params.has_key?(:email))
      else
        render json: failed_json, status: 422
      end
    rescue Invite::UserExists => e
      render_json_error(e.message)
    rescue ActiveRecord::RecordInvalid => e
      render_json_error(e.record.errors.full_messages.first)
    end
  end

  def retrieve
    params.require(:email)

    invite = Invite.find_by(invited_by: current_user, email: params[:email])
    raise Discourse::InvalidParameters.new(:email) if invite.blank?

    guardian.ensure_can_invite_to_forum!(nil)

    render_serialized(invite, InviteSerializer, scope: guardian, root: nil, show_emails: params.has_key?(:email))
  end

  def update
    invite = Invite.find_by(invited_by: current_user, id: params[:id])
    raise Discourse::InvalidParameters.new(:id) if invite.blank?

    if params[:topic_id].present?
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::InvalidParameters.new(:topic_id) if topic.blank?
      guardian.ensure_can_invite_to!(topic)
    end

    if params[:group_ids].present? || params[:group_names].present?
      groups = Group.lookup_groups(group_ids: params[:group_ids], group_names: params[:group_names])
    end

    guardian.ensure_can_invite_to_forum!(groups)

    Invite.transaction do
      if params.has_key?(:topic_id)
        invite.topic_invites.destroy_all
        invite.topic_invites.create!(topic_id: topic.id) if topic.present?
      end

      if params.has_key?(:group_ids) || params.has_key?(:group_names)
        invite.invited_groups.destroy_all
        groups.each { |group| invite.invited_groups.find_or_create_by!(group_id: group.id) } if groups.present?
      end

      if params.has_key?(:email)
        old_email = invite.email.presence
        new_email = params[:email].presence

        if old_email != new_email
          invite.emailed_status = if new_email && !params[:skip_email]
            Invite.emailed_status_types[:pending]
          else
            Invite.emailed_status_types[:not_required]
          end
        end
      end

      if params[:send_email]
        if invite.emailed_status != Invite.emailed_status_types[:pending]
          begin
            RateLimiter.new(current_user, "resend-invite-per-hour", 10, 1.hour).performed!
          rescue RateLimiter::LimitExceeded
            return render_json_error(I18n.t("rate_limiter.slow_down"))
          end
        end

        invite.emailed_status = Invite.emailed_status_types[:pending]
      end

      begin
        invite.update!(params.permit(:email, :custom_message, :max_redemptions_allowed, :expires_at))
      rescue ActiveRecord::RecordInvalid => e
        return render_json_error(e.record.errors.full_messages.first)
      end
    end

    if invite.emailed_status == Invite.emailed_status_types[:pending]
      invite.update_column(:emailed_status, Invite.emailed_status_types[:sending])
      Jobs.enqueue(:invite_email, invite_id: invite.id, invite_to_topic: params[:invite_to_topic])
    end

    render_serialized(invite, InviteSerializer, scope: guardian, root: nil, show_emails: params.has_key?(:email))
  end

  def destroy
    params.require(:id)

    invite = Invite.find_by(invited_by_id: current_user.id, id: params[:id])
    raise Discourse::InvalidParameters.new(:id) if invite.blank?

    invite.trash!(current_user)

    render json: success_json
  end

  # For DiscourseConnect SSO, all invite acceptance is done
  # via the SessionController#sso_login route
  def perform_accept_invitation
    params.require(:id)
    params.permit(:email, :username, :name, :password, :timezone, :email_token, user_custom_fields: {})

    invite = Invite.find_by(invite_key: params[:id])

    if invite.present?
      begin
        attrs = {
          username: params[:username],
          name: params[:name],
          password: params[:password],
          user_custom_fields: params[:user_custom_fields],
          ip_address: request.remote_ip,
          session: session
        }

        if invite.is_invite_link?
          params.require(:email)
          attrs[:email] = params[:email]
        else
          attrs[:email] = invite.email
          attrs[:email_token] = params[:email_token] if params[:email_token].present?
        end

        user = invite.redeem(**attrs)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, Invite::UserExists => e
        return render json: failed_json.merge(message: e.message), status: 412
      end

      if user.blank?
        return render json: failed_json.merge(message: I18n.t('invite.not_found_json')), status: 404
      end

      log_on_user(user) if user.active?
      user.update_timezone_if_missing(params[:timezone])
      post_process_invite(user)

      topic = invite.topics.first
      response = {}

      if user.present? && user.active?
        response[:redirect_to] = topic.present? ? path(topic.relative_url) : path("/")
      elsif user.present?
        response[:message] = I18n.t('invite.confirm_email')
        cookies[:destination_url] = path(topic.relative_url) if topic.present?
      end

      render json: success_json.merge(response)
    else
      render json: failed_json.merge(message: I18n.t('invite.not_found_json')), status: 404
    end
  end

  def destroy_all_expired
    guardian.ensure_can_destroy_all_invites!(current_user)

    Invite
      .where(invited_by: current_user)
      .where('expires_at < ?', Time.zone.now)
      .find_each { |invite| invite.trash!(current_user) }

    render json: success_json
  end

  def resend_invite
    params.require(:email)
    RateLimiter.new(current_user, "resend-invite-per-hour", 10, 1.hour).performed!

    invite = Invite.find_by(invited_by_id: current_user.id, email: params[:email])
    raise Discourse::InvalidParameters.new(:email) if invite.blank?
    invite.resend_invite
    render json: success_json
  rescue RateLimiter::LimitExceeded
    render_json_error(I18n.t("rate_limiter.slow_down"))
  end

  def resend_all_invites
    guardian.ensure_can_resend_all_invites!(current_user)

    Invite
      .left_outer_joins(:invited_users)
      .where(invited_by: current_user)
      .where('invites.email IS NOT NULL')
      .where('invited_users.user_id IS NULL')
      .group('invites.id')
      .find_each { |invite| invite.resend_invite }

    render json: success_json
  end

  def upload_csv
    guardian.ensure_can_bulk_invite_to_forum!(current_user)

    hijack do
      begin
        file = params[:file] || params[:files].first

        csv_header = nil
        invites = []

        CSV.foreach(file.tempfile, encoding: "bom|utf-8") do |row|
          # Try to extract a CSV header, if it exists
          if csv_header.nil?
            if row[0] == 'email'
              csv_header = row
              next
            else
              csv_header = ["email", "groups", "topic_id"]
            end
          end

          if row[0].present?
            invites.push(csv_header.zip(row).map.to_h.filter { |k, v| v.present? })
          end

          break if invites.count >= SiteSetting.max_bulk_invites
        end

        if invites.present?
          Jobs.enqueue(:bulk_invite, invites: invites, current_user_id: current_user.id)

          if invites.count >= SiteSetting.max_bulk_invites
            render json: failed_json.merge(errors: [I18n.t("bulk_invite.max_rows", max_bulk_invites: SiteSetting.max_bulk_invites)]), status: 422
          else
            render json: success_json
          end
        else
          render json: failed_json.merge(errors: [I18n.t("bulk_invite.error")]), status: 422
        end
      end
    end
  end

  private

  def ensure_invites_allowed
    if (!SiteSetting.enable_local_logins && Discourse.enabled_auth_providers.count == 0 && !SiteSetting.enable_discourse_connect)
      raise Discourse::NotFound
    end
  end

  def ensure_new_registrations_allowed
    unless SiteSetting.allow_new_registrations
      flash[:error] = I18n.t('login.new_registrations_disabled')
      render layout: 'no_ember'
      false
    end
  end

  def ensure_not_logged_in
    if current_user
      flash[:error] = I18n.t("login.already_logged_in")
      render layout: 'no_ember'
      false
    end
  end

  def post_process_invite(user)
    user.enqueue_welcome_message('welcome_invite') if user.send_welcome_message

    Group.refresh_automatic_groups!(:admins, :moderators, :staff) if user.staff?

    if user.has_password?
      send_activation_email(user) unless user.active
    elsif !SiteSetting.enable_discourse_connect && SiteSetting.enable_local_logins
      Jobs.enqueue(:invite_password_instructions_email, username: user.username)
    end
  end

  def send_activation_email(user)
    email_token = user.email_tokens.create!(email: user.email)

    Jobs.enqueue(:critical_user_email,
                 type: :signup,
                 user_id: user.id,
                 email_token: email_token.token
    )
  end
end
