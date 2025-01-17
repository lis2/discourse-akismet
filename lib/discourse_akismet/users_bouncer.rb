# frozen_string_literal: true

module DiscourseAkismet
  class UsersBouncer
    VALID_STATUSES = %w[spam ham]

    def should_check_user?(user)
      SiteSetting.akismet_review_users &&
        user.trust_level === TrustLevel[0] &&
        user.user_profile.bio_raw.present? &&
        user.user_auth_token_logs&.last&.client_ip.present? &&
        !Reviewable.exists?(target: user)
    end

    def enqueue_for_check(user)
      return if !should_check_user?(user)
      Jobs.enqueue(:check_users_for_spam, user_id: user.id)
    end

    def check_user(client, user)
      return if !should_check_user?(user)

      if client.comment_check(args_for_user(user))
        spam_reporter = Discourse.system_user

        reviewable = ReviewableAkismetUser.needs_review!(
          target: user, reviewable_by_moderator: true,
          created_by: spam_reporter,
          payload: { username: user.username, name: user.name, email: user.email, bio: user.user_profile.bio_raw }
        )

        reviewable.add_score(
          spam_reporter, PostActionType.types[:spam],
          created_at: reviewable.created_at,
          reason: 'akismet_spam_user'
        )
      end
    end

    def submit_feedback(user, status)
      raise Discourse::InvalidParameters.new(:status) unless VALID_STATUSES.include?(status)
      feedback = args_for_user(user)

      Jobs.enqueue(:update_akismet_status, feedback: feedback, status: status)
    end

    private

    def args_for_user(user)
      profile = user.user_profile
      token = user.user_auth_token_logs.last

      extra_args = {
        content_type: 'signup',
        permalink: "#{Discourse.base_url}/u/#{user.username_lower}",
        comment_author: user.username,
        comment_content: profile.bio_raw,
        comment_author_url: profile.website,
        user_ip: token.client_ip.to_s,
        user_agent: token.user_agent
      }

      # Sending the email to akismet is optional
      if SiteSetting.akismet_transmit_email?
        extra_args[:comment_author_email] = user.email
      end

      extra_args
    end
  end
end
