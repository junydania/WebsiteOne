class EventInstancesController < ApplicationController
  skip_before_filter :verify_authenticity_token
  before_filter :cors_preflight_check, except: [:index, :edit, :update_link]
  before_action :authenticate_user!, only: [:edit, :update_link]

  def update
    event_instance = EventInstance.find_or_create_by(uid: params[:id])

    event_instance_params = check_and_transform_params(event_instance)
    hangout_url_changed = event_instance.hangout_url != event_instance_params[:hangout_url]
    yt_video_id_changed = event_instance.yt_video_id != event_instance_params[:yt_video_id]
    slack_notify_hangout = params[:notify_hangout] == 'true'
    slack_notify_yt = params[:notify_yt] == 'true'
    if event_instance.try!(:update, event_instance_params)
      SlackService.post_hangout_notification(event_instance) if (slack_notify_hangout && event_instance.hangout_url?) || (event_instance.started? && hangout_url_changed)
      SlackService.post_yt_link(event_instance) if (slack_notify_yt && event_instance.yt_video_id?) || yt_video_id_changed

      TwitterService.tweet_hangout_notification(event_instance) if event_instance.started? && hangout_url_changed
      TwitterService.tweet_yt_link(event_instance)

      redirect_to(event_path params[:event_id]) && return if local_request? && params[:event_id].present?
      head :ok
    else
      head :internal_server_error
    end
  end

  def index
    relation = (params[:live] == 'true') ? EventInstance.live : EventInstance.latest
    relation = relation.includes(:project, :event, :user)
    @event_instances = relation.paginate(:page => params[:page], per_page: 5)
  end

  def edit
    @event_instance = EventInstance.find(params[:id])
  end

  def update_link
    @event_instance = EventInstance.find(params[:id])
    youtube_id = YouTubeRails.extract_video_id(event_instance_params[:yt_video_id])
    if youtube_id && @event_instance.update_attributes(yt_video_id: youtube_id, hoa_status: event_instance_params[:hoa_status] )
      flash[:notice] = "Hangout Updated"
      redirect_to edit_event_instance_path(@event_instance)
    else
      flash[:alert] = "Error.  Please Try again"
      redirect_to edit_event_instance_path(@event_instance)
    end
  end

  private

  def event_instance_params
    params.require(:event_instance).permit(:yt_video_id, :hoa_status)
  end

  def cors_preflight_check
    head :bad_request and return unless (allowed? || local_request?)

    set_cors_headers
    head :ok and return if request.method == 'OPTIONS'
  end

  def allowed?
    allowed_sites = %w(a-hangout-opensocial.googleusercontent.com)
    origin = request.env['HTTP_ORIGIN']
    allowed_sites.any? { |url| origin =~ /#{url}/ }
  end

  def local_request?
    request.env['HTTP_ORIGIN'].include?(request.env['HTTP_HOST'])
  end

  def set_cors_headers
    response.headers['Access-Control-Allow-Origin'] = request.env['HTTP_ORIGIN']
    response.headers['Access-Control-Allow-Methods'] = 'PUT'
  end

  def check_and_transform_params(event_instance)
    params.require(:host_id)
    params.require(:title)

    transform_params(event_instance)
  end

  def transform_params(event_instance)
    ActionController::Parameters.new(
        title: params[:title],
        project_id: params[:project_id],
        event_id: params[:event_id],
        category: params[:category],
        user_id: params[:host_id],
        hangout_participants_snapshots_attributes: [{participants: params[:participants]}],
        participants: merge_participants(event_instance.participants, params[:participants]),
        hangout_url: params[:hangout_url],
        yt_video_id: YouTubeRails.extract_video_id(params[:yt_url]) || params[:yt_video_id],
        hoa_status: params[:hoa_status],
        url_set_directly: params[:url_set_directly],
        updated_at: Time.now,
        youtube_tweet_sent: params[:you_tube_tweet_sent]
    ).permit!
  end

  def merge_participants(existing_participants, new_participants)
    return new_participants unless existing_participants
    return existing_participants unless new_participants
    new_participants.each do |_, v|
      unless existing_participants.values.any? { |struc| struc['person']['id'] == v['person']['id'] }
        existing_participants[existing_participants.length.to_s] = v
      end
    end
    return existing_participants
  end
end
