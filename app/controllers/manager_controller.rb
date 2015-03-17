ACCT_NAME = YAML.load_file("#{Rails.root}/config/canvas_spaces.yml")[Rails.env]['acct_name']
GROUP_CAT_NAME = YAML.load_file("#{Rails.root}/config/canvas_spaces.yml")[Rails.env]['group_cat_name']

class ManagerController < ApplicationController
  before_filter :require_user

  #
  # Routes to the CAS login page automatically if the
  # authentication cookie hasn't been set.
  #
  def login
    # the method by which to authenticate and get a token that will allow
    # us to call the REST api
  end

  #
  # Destroys the session.
  #
  def logout
    # TODO
  end

  #
  # Convert from internal value to user-friendly type used
  # by our API.
  #
  def display_join_type(join_level)
    case join_level
      when "invitation_only"
        "invite_only"
      when "parent_context_auto_join"
        "free_to_join"
      when "parent_context_request"
        "request"
      else
        "unknown:" + join_level
      end
  end

  #
  # List all groups in the special group set that belongs to the
  # special account.
  # TODO: implement paging support
  #
  def list_groups
    group_cat = GroupCategory.find_by_name(GROUP_CAT_NAME)

    groups = group_cat.groups
             .where("groups.workflow_state != 'deleted'")
             .eager_load(:users)

    render json: { size: groups.count,
                   groups: groups.map do |g|
                        g.as_json(only: [:id, :name, :leader_id, :created_at, :description], 
                                  include_root: false)
                         .merge({ size: g.users.count, join_type: display_join_type(g.join_level) }) 
                   end
                 },
           status: :ok
  end

  #
  # Create a group.
  # If called by a non-admin user then the user will be made leader of the group. 
  # Any specified leader is ignored.
  # If called by an admin a leader may be specified.
  # leader is canvas id
  # join_type is either: 'request', free_to_join' or 'invite_only'
  #
  def create_group
    group_cat = GroupCategory.find_by_name(GROUP_CAT_NAME)
    acct = Account.find_by_name(ACCT_NAME)

    name_param = params[:name]
    leader_id_param = params[:leader_id]
    join_type_param = params[:join_type] 
    desc_param = params[:desc]

    if name_param.nil? || name_param.blank?
      render json: { error: 'No name specified.' }, status: :bad_request
      return
    end

    if join_type_param.nil? || join_type_param.blank?
      render json: { error: 'No join_type specified.' }, status: :bad_request
      return
    end

    if @current_user.account.site_admin?
      if leader_id_param && !leader_id_param.blank?
        leader = User.find_by_id(leader_id_param)
        if leader.nil?
          render json: { error: "Can't find user specified for leader." }, status: :bad_request
          return
        end
      else
        leader = nil
      end
    else
      # if a non-admin is creating the group then
      # the leader is that user and that id is used to determine who "owns"
      # the group and can make changes to it
      leader = @current_user
    end

    if join_type_param == 'free_to_join'
      join_type = 'parent_context_auto_join'
    elsif join_type_param == 'request'
      join_type = 'parent_context_request'
    elsif join_type_param == 'invite_only'
      join_type = 'invitation_only'
    else
      render json: { error: 'Invalid join_type value. Valid: request, free_to_join, invite_only.' }, status: :bad_request
      return
    end

    group = acct.groups.create( name: name_param,
                                group_category: group_cat,
                                leader: leader,
                                join_level: join_type,
                                description: desc_param )
    group.add_user(leader) if !leader.nil?
    group.save

    render json: group.as_json(only: [ :id, :name, :description, :leader_id, :created_at ], 
                               include_root: false)
                      .merge({ size: 0, join_type: join_type_param }), status: :ok
  end

  #
  # Return info on a group.
  # Anyone can access this information.
  #
  def group_info
    group_cat = GroupCategory.find_by_name(GROUP_CAT_NAME)

    group_id_param = params[:group_id]

    if group_id_param.nil? || group_id_param.blank?
      render json: { error: 'group_id not specified.' }, status: :bad_request
      return
    end

    group = group_cat
            .groups
            .where('groups.id = ?', group_id_param)
            .eager_load(:users)
            .first
    if group.nil?
      render json: { error: 'No such group found.' }, status: :not_found
    else
      render json: { id: group.id,
                     name: group.name,
                     description: group.description,
                     leader_id: group.leader_id,
                     created_at: group.created_at,
                     join_type: display_join_type(group.join_level),
                     size: group.users.count
                   },
             status: :ok
    end
  end

  #
  # Change group properties: description or join type.
  #
  def modify_group
    group_cat = GroupCategory.find_by_name(GROUP_CAT_NAME)

    group_id_param = params[:group_id]
    desc_param = params[:desc]
    join_type_param = params[:join_type]

    if group_id_param.nil? || group_id_param.blank?
      render json: { error: 'group_id not specified.' }, status: :bad_request
      return
    end

    group = group_cat.groups.where('groups.id = ?', group_id_param).first
    if group.nil?
      render json: { error: 'No such group found.' }, status: :not_found
    else
      if @current_user.account.site_admin? || group.leader_id == @current_user.id
        
        group.description = desc_param if desc_param && !desc_param.blank?

        if join_type_param && !join_type_param.blank?
          if join_type_param == 'free_to_join'
            group.join_level = 'parent_context_auto_join'
          elsif join_type_param == 'request'
            group.join_level = 'parent_context_request'                
          elsif join_type_param == 'invite_only'
            group.join_level = 'invitation_only'
          else
            render json: { error: 'Invalid join_type value. Valid: request, free_to_join, invite_only.' }, status: :bad_request
            return
          end
        end

        group.save
        render json: { message: 'Successfully modified group.' }, status: :ok
      else
        render json: { error: "Can't modify group. Not owner." }, status: :forbidden
      end
    end
  end

  #
  # List the users in the group as well as the number of users.
  #
  def list_users
    group_cat = GroupCategory.find_by_name(GROUP_CAT_NAME)

    group_id_param = params[:group_id]

    if group_id_param.nil? || group_id_param.blank?
      render json: { error: 'group_id not specified.' }, status: :bad_request
      return
    end

    group = group_cat.groups.find_by_id(group_id_param)
    if group.nil?
      render json: { error: 'No such group found.' }, status: :bad_request
    else
      if @current_user.account.site_admin? || group.leader_id == @current_user.id
        render json: { size: group.users.count, users: group.users.map { |user| user.as_json(only: [:id, :name], include_root: false) } }, status: :ok
      else
        # doesn't have access to the group
        render json: { error: "Can't list users. Not owner." }, status: :forbidden
      end
    end
  end

  #
  # Add user to a group.
  # The site admin can add any user to a group.
  # The leader of the group may add any user. TODO: Should this be allowed?
  # What if the user doesn't want to be a member of the group?
  # A user may add himself/herself to a group.
  # user = Canvas id of student
  # TODO: How is this affected by the join_level?
  #
  def add_user
    group_cat = GroupCategory.find_by_name(GROUP_CAT_NAME) # TODO: refactor this since it's used everywhere

    group_id_param = params[:group_id]
    user_id_param = params[:user_id]

    if group_id_param.nil? || group_id_param.blank?
      render json: { error: 'group_id not specified.' }, status: :bad_request
      return
    end

    if user_id_param.nil? || user_id_param.blank?
      render json: { error: 'user_id not specified.' }, status: :bad_request
      return
    end

    user = User.find_by_id(user_id_param)
    if user.nil?
      render json: { error: "Can't find user #{user_id_param}." }, status: :bad_request
      return
    end

    group = group_cat.groups.find_by_id(group_id_param)
    if group.nil?
      render json: { error: 'No such group found.' }, status: :bad_request
    else
      if @current_user.account.site_admin? ||
         group.leader_id == @current_user.id ||
         @current_user.id == user.id

        group.add_user user
        group.save

        render json: { message: 'Successfully added user.' }, status: :ok
      else
        # doesn't have access to the group
        render json: { error: "Can't add user. Not owner or not adding self." }, status: :forbidden
      end
    end
  end

  #
  # Remove user from a group.
  # The site admin can remove any user from a group.
  # The leader of the group may remove any user.
  # A user may remove himself/herself to a group.
  # user_id = canvas id of user to remove
  # Can't remove user if he/she is the leader. Someone else must be made leader first.
  #
  def remove_user
    group_cat = GroupCategory.find_by_name(GROUP_CAT_NAME) # TODO: refactor this since it's used everywhere

    group_id_param = params[:group_id]
    user_id_param = params[:user_id]

    if group_id_param.nil? || group_id_param.blank?
      render json: { error: 'group_id not specified.' }, status: :bad_request
      return
    end

    if user_id_param.nil? || user_id_param.blank?
      render json: { error: 'user_id not specified.' }, status: :bad_request
      return
    end

    user = User.find_by_id(user_id_param)
    if user.nil?
      render json: { error: "Remove failed. Can't find user #{user_param}." }, status: :bad_request
      return
    end

    group = group_cat.groups.find_by_id(group_id_param)
    if group.nil?
      render json: { error: 'No such group found.' }, status: :bad_request
    else
      if @current_user.account.site_admin? || group.leader_id == @current_user.id || @current_user.id == user.id
        if group.leader_id == user.id
          render json: { error: "Can't remove user that is the leader of the group." }, status: :bad_request
          return
        end

        membership = group.group_memberships.where(user_id: user).first
        membership.workflow_state = 'deleted'
        membership.save
        render json: { message: 'Successfully removed user.' }, status: :ok
      else
        # doesn't have access to the group
        render json: { error: "Can't remove user. Not owner or not adding self." }, status: :forbidden
      end
    end
  end

  #
  # Change leadership of the group.
  # Admin may set anyone as leader of the group.
  # Leader of the group may set anyone as leader of the group.
  # I don't check to see if the new leader is a member of the group.
  #
  def set_leader
    group_cat = GroupCategory.find_by_name(GROUP_CAT_NAME) # TODO: refactor this since it's used everywhere

    group_id_param = params[:group_id]
    leader_id_param = params[:leader_id]

    if leader_id_param.nil? || leader_id_param.blank?
      render json: { error: 'No leader_id supplied.' }, status: :bad_request
      return
    end

    # lookup canvas id by sfu-id
    leader = User.find_by_id(leader_id_param)
    if leader.nil?
      render json: { error: "Leader change failed. Can't find user #{leader_id_param}." }, status: :bad_request
      return
    end

    group = group_cat.groups.find_by_id(group_id_param)
    if group.nil?
      render json: { error: 'No such group found.' }, status: :bad_request
    else
      if @current_user.account.site_admin? || group.leader_id == @current_user.id
        # New leader must be a member of the group.
        group.add_user(leader) # this call is idempotent so we can call it even if the user is already a member
        group.leader_id = leader.id
        group.save
        render json: { message: 'Successfully changed leader.' }, status: :ok
      else
        # doesn't have access to the group
        render json: { error: "Can't change leader. Not owner." }, status: :forbidden
      end
    end
  end

  #
  # Test method.
  # Returns a list of all the users in the db.
  #
  def test_get_user_list
    if Rails.env.development?
      render json: User.all.map { |user| user.as_json(only: [:id, :name], include_root: false) }
    end
  end
end
