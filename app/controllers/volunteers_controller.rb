class VolunteersController < ApplicationController
  before_filter :authenticate_volunteer!
  before_filter :admin_only, :only => [:knight, :unassigned, :shiftless, :shiftless_old, :admin, :switch_user, :stats]

  def unassigned
    unassigned = Volunteer.where(assigned: false)
    no_assignments = Volunteer.where('((SELECT COUNT(*) FROM assignments a WHERE a.volunteer_id=volunteers.id)=0)')
    unrequested = Volunteer.where(requested_region_id: nil)
    requested_my_region = Volunteer.where(requested_region_id: current_volunteer.admin_region_ids)
    @volunteers = unassigned | (no_assignments & (unrequested | requested_my_region))
    @header = 'Unassigned Volunteers'
  end

  def assign
    v = Volunteer.find(params[:volunteer_id])
    r = Region.find(params[:region_id])
    if params[:unassign]
      Assignment.where(:volunteer_id=>v.id, :region_id=>r.id).each{ |e| e.destroy }
      if v.assignments.length == 0
        v.assigned = false
        v.save
      end
    else
      Assignment.add_volunteer_to_region v, r
      unless params[:send_welcome_email].nil? or params[:send_welcome_email].to_i != 1
        m = Notifier.region_welcome_email(r, v)
        m.deliver unless m.nil?
      end
      v.save
    end
    redirect_to :action => 'unassigned', :alert => 'Assignment worked'
  end

  def shiftless
    @volunteers = Volunteer.all.keep_if do |v|
      ((v.region_ids & current_volunteer.region_ids).length > 0) and v.schedule_chains.length == 0
    end
    @header = 'Shiftless Volunteers'
    render :index
  end

  def active
    @volunteers = Volunteer.active(current_volunteer.region_ids)
    @header = 'Active Volunteers'
    render :index
  end

  def inactive
    @volunteers = Volunteer.inactive(current_volunteer.region_ids)
    @header = 'Inactive (Disabled) Volunteer Accounts'
    render :index
  end

  def need_training
    @volunteers = Volunteer.all.keep_if{ |v|
      ((v.region_ids & current_volunteer.region_ids).length > 0) and v.needs_training?
    }
    @header = 'Volunteers Needing Training'
    render :index
  end

  def index
    @header = 'All Volunteers'
    respond_to do |format|
      format.json {
        @volunteers = Volunteer.select('email,id,name,phone').collect{ |v| (v.regions.collect{ |r| r.id } & current_volunteer.region_ids).length > 0 ? v : nil }.compact
        render json: @volunteers.to_json
      }
      format.html {
        @volunteers = Volunteer.includes(:regions).
                        all.collect { |volunteer|
                          (volunteer.regions.collect{ |region| region.id } & current_volunteer.region_ids).length > 0 ? volunteer : nil
                        }.compact
        render :index
      }
    end
  end

  def show
    @v = Volunteer.find(params[:id])
    unless current_volunteer.super_admin? or (current_volunteer.region_ids & @v.region_ids).length > 0
      flash[:error] = "Can't view volunteer for a region you're not assigned to..."
      redirect_to(root_path)
      return
    end
  end

  def destroy
    @v = Volunteer.find(params[:id])
    return unless check_permissions(@v)
    @v.active = false
    @v.save
    redirect_to(request.referrer)
  end

  def new
    @volunteer = Volunteer.new
    @action = 'create'
    @regions = Region.all
    @my_admin_regions = if current_volunteer.super_admin?
                          @regions
                        else
                          current_volunteer.assignments.collect{ |a| a.admin ? a.region : nil }.compact
                        end
    session[:my_return_to] = request.referer
    flash[:notice] = 'Thanks for signing up! You will recieve an email shortly when a regional admin approves your registration.'
    render :new
  end

  def check_permissions(v)
    unless current_volunteer.super_admin? or (current_volunteer.admin_region_ids & v.region_ids).length > 0 or
           current_volunteer == v
      flash[:error] = 'Not authorized to create/edit volunteers for that region'
      redirect_to(root_path)
      return false
    end
    return true
  end

  def create
    @volunteer = Volunteer.new(params[:volunteer])
    return unless check_permissions(@volunteer)
    # can't set admin bits from CRUD controls
    @volunteer.admin = false
    @volunteer.assignments.each{ |r| r.admin = false }
    if @volunteer.save
      flash[:notice] = 'Created successfully.'
      unless session[:my_return_to].nil?
        redirect_to(session[:my_return_to])
      else
        index
      end
    else
      flash[:error] = "Didn't save successfully :("
      render :new
    end
  end

  def edit
    @volunteer = Volunteer.find(params[:id])
    return unless check_permissions(@volunteer)
    @regions = Region.all
    @my_admin_regions = if current_volunteer.super_admin?
                          @regions
                        else
                          current_volunteer.assignments.collect{ |a| a.admin ? a.region : nil }.compact
                        end
    @action = 'update'
    session[:my_return_to] = request.referer
    render :edit
  end

  def update
    @volunteer = Volunteer.find(params[:id])
    return unless check_permissions(@volunteer)
    # can't set admin bits from CRUD controls
    params[:volunteer].delete(:admin)
    params[:volunteer][:assignments].each{ |a| a.delete(:admin) } unless params[:volunteer][:assignments].nil?
    if @volunteer.update_attributes(params[:volunteer])
      flash[:notice] = "Updated #{@volunteer.name} Successfully."
      unless session[:my_return_to].nil?
        redirect_to(session[:my_return_to])
      else
        index
      end
    else
      flash[:error] = 'Update failed :('
      render :edit
    end
  end

  # switch to a particular user
  def switch_user
    v = Volunteer.find(params[:volunteer_id].to_i)
    vrids = v.regions.collect{ |r| r.id }
    adminrids = current_volunteer.assignments.collect{ |a| a.admin ? a.region.id : nil }.compact
    unless current_volunteer.super_admin? or (vrids & adminrids).length > 0
      flash[:error] = "You're not authorized to switch to that user!"
      redirect_to(root_path)
      return
    end
    sign_out(current_volunteer)
    sign_in(v)
    flash[:notice] = "Successfully switched to user #{current_volunteer.name}."
    home
  end

  # special settings/stats page for admins only
  def super_admin
  end

  def region_admin
    @regions = Region.all
    if current_volunteer.super_admin?
      @my_admin_regions = @regions
      @my_admin_volunteers = Volunteer.all
    else
      @my_admin_regions = current_volunteer.assignments.collect{ |a| a.admin ? a.region : nil }.compact
      adminrids = @my_admin_regions.collect{ |m| m.id }
      @my_admin_volunteers = Volunteer.all.collect{ |v|
        ((v.regions.length == 0) or (adminrids & v.regions.collect{ |r| r.id }).length > 0) ? v : nil }.compact
    end
  end

  # Admin only view, hence use of #admin_regions for region lookup
  def stats
    @regions = current_volunteer.admin_regions
    region_ids = @regions.collect{ |x| x.id }.join(',')
    @logs_per_volunteer_year =
      Log.joins(:log_parts, :volunteers).
        select('volunteers.id, volunteers.name, sum(weight), count(DISTINCT logs.id)').
        where("complete AND region_id IN (#{region_ids}) and logs.when > ?", Date.today-12.months).
        group('volunteers.id, volunteers.name').order('sum DESC')
    @logs_per_volunteer_month =
      Log.joins(:log_parts, :volunteers).
        select('volunteers.id, volunteers.name, sum(weight), count(DISTINCT logs.id)').
        where("complete AND region_id IN (#{region_ids}) and logs.when > ?", Date.today-1.month).
        group('volunteers.id, volunteers.name').order('sum DESC')

    @lazy_volunteers =
      Volunteer.select('volunteers.id, name, email, count(*) as count, max("when") as last_date').
            joins(:logs, :log_volunteers).
            where("volunteers.id=log_volunteers.volunteer_id and logs.region_id IN (#{current_volunteer.admin_region_ids.join(',')})").
            group('volunteers.id, name, email')
  end

  def shift_stats
    @region = Region.where(id: params[:region_id]).first
    @regions = current_volunteer.admin_regions

    # Only if they have selected from dropdown and GET-ed back to here
    if @region.present?
      @volunteers = Volunteer.includes(:logs).joins(:logs).where("logs.complete = true AND logs.region_id IN (#{@region.id})")
      @shifts_by_volunteer =
        @volunteers.map do |vol|
          # vol.logs prevents add'l DB lookup as complete logs eager loaded
          [vol, Shift.build_shifts_eagerly(vol.logs.map(&:id))]
        end.to_h
    else # Need to select a region
      @shifts_by_volunteer = []
    end
  end

  def knight
    unless current_volunteer.super_admin?
      flash[:error] = "You're not permitted to do that!"
      redirect_to(root_path)
      return
    end

    volunteer = Volunteer.find(params[:volunteer_id])
    if ToggleSuperAdmin.call(volunteer: volunteer).success?
      flash[:notice] = "#{volunteer.name} Updated to Admin: #{volunteer.admin}"
    else
      flash[:error] = "#{volunteer.errors.full_messages}"
    end
    redirect_to(super_admin_volunteers_path)
  end

  def reactivate
    v = Volunteer.send(:with_exclusive_scope){ Volunteer.find(params[:id]) }
    if (current_volunteer.admin_region_ids & v.region_ids).length <= 0
      flash[:error] = "You're not permitted to do that!"
      redirect_to(root_path)
      return
    end
    unless ReactivateVolunteer.call(volunteer: v).success?
      flash[:error] = 'Update failed :('
    end
    inactive
  end

  def admin_only
    redirect_to(root_path) unless current_volunteer.any_admin?
  end

  def home
    unless current_volunteer.waiver_signed?
      return redirect_to new_waiver_url
    end

    @open_shift_count = ScheduleChain.open_in_regions(current_volunteer.region_ids).length

    # Upcoming pickup list
    @upcoming_pickups = Shift.build_shifts(Log.upcoming_for(current_volunteer.id))
    @shifts_needing_cov = Shift.build_shifts(Log.needing_coverage(current_volunteer.region_ids, 7, 10))
    @total_shifts_needing_cov = Log.needing_coverage(current_volunteer.region_ids, 7).length

    # To Do Pickup Reports
    @to_do_reports = Log.picked_up_by(current_volunteer.id, false)

    @by_month = {}
    Log.picked_up_by(current_volunteer.id).each do |log|
      year_month = log.when.strftime('%Y-%m')
      @by_month[year_month] = 0.0 if @by_month[year_month].nil?
      @by_month[year_month] += log.summed_weight unless log.summed_weight.nil?
    end

    @volunteer_stats_presenter = VolunteerStatsPresenter.new(current_volunteer)

    render :home
  end
end
