class ArtefactsController < ApplicationController
  before_filter :find_artefact, :only => [:show, :edit, :history, :archive]
  before_filter :build_artefact, :only => [:new, :create]
  before_filter :tag_collection, :except => [:show]
  helper_method :relatable_items
  helper_method :sort_column, :sort_direction

  respond_to :html, :json

  ITEMS_PER_PAGE = 100

  def index
    @filters = params.slice(:section, :specialist_sector, :kind, :state, :search)
    @scope = apply_filters(artefact_scope, @filters)

    @scope = @scope.order_by([[sort_column, sort_direction]])
    @artefacts = @scope.page(params[:page]).per(ITEMS_PER_PAGE)
    respond_with @artefacts, @tag_collection
  end

  def show
    respond_with @artefact do |format|
      format.html { redirect_to admin_url_for_edition(@artefact) }
    end
  end

  def history
    @actions = build_actions
  end

  def archive

  end

  def new
    redirect_to_show_if_need_met
  end

  def edit
  end

  def create
    @artefact.save_as current_user
    continue_editing = (params[:commit] == 'Save and continue editing')
    if continue_editing || @artefact.owning_app != "publisher"
      location = edit_artefact_path(@artefact.id)
    else
      location = admin_url_for_edition(@artefact, params.slice(:return_to))
    end
    respond_with @artefact, location: location
  end

  # NB: We are departing from usual rails conventions here. PUTing a resource
  # will create it if it doesn't exist, rather than the usual 404.
  def update
    begin
      @artefact = Artefact.from_param(params[:id])
      status_to_use = 200
    rescue Mongoid::Errors::DocumentNotFound
      @artefact = Artefact.new(slug: params[:id])
      status_to_use = 201
    end

    parameters_to_use = extract_parameters(params)

    if attempting_to_change_owning_app?(parameters_to_use)
      render(
        text: "This artefact already belongs to the
               '#{@artefact.owning_app}' app",
        status: 409
      )
      return
    end

    saved = @artefact.update_attributes_as(current_user, parameters_to_use)
    flash[:notice] = saved ? 'Panopticon item updated' : 'Failed to save item'

    @actions = build_actions
    respond_with @artefact, status: status_to_use do |format|
      format.html do
        continue_editing = (params[:commit] == 'Save and continue editing')
        if saved && (continue_editing || (@artefact.owning_app != "publisher"))
          redirect_to edit_artefact_path(@artefact)
        else
          respond_with @artefact, status: status_to_use
        end
      end
      format.json do
        if saved
          render json: @artefact.to_json, status: status_to_use
        else
          render json: {"errors" => @artefact.errors.full_messages}, status: 422
        end
      end
    end
  end

  def destroy
    @artefact = Artefact.from_param(params[:id])
    @artefact.update_attributes_as(current_user, state: "archived")
    respond_with(@artefact) do |format|
      format.json { head 200 }
      format.html { redirect_to artefacts_path }
    end
  end

  private

    def admin_url_for_edition(artefact, options = {})
      [
        "#{Plek.current.find(artefact.owning_app)}/admin/publications/#{artefact.id}",
        options.to_query
      ].reject(&:blank?).join("?")
    end

    def artefact_scope
      # This is here so that we can stub this out a bit more easily in the
      # functional tests.
      Artefact
    end

    def apply_filters(scope, filters)
      [:section, :specialist_sector].each do |tag_type|
        if filters[tag_type].present?
          scope = scope.with_parent_tag(tag_type, filters[tag_type])
        end
      end

      if filters[:state].present? && Artefact::STATES.include?(filters[:state])
        scope = scope.in_state(filters[:state])
      end

      if filters[:kind].present? && Artefact::FORMATS.include?(filters[:kind])
        scope = scope.of_kind(filters[:kind])
      end

      if filters[:search].present?
        scope = scope.matching_query(filters[:search])
      end

      scope
    end

    def tag_collection
      @tag_collection = Tag.where(:tag_type => 'section')
                                     .asc(:title).to_a

      title_counts = Hash.new(0)
      @tag_collection.each do |tag|
        title_counts[tag.title] += 1
      end

      @tag_collection.each do |tag|
        tag.uniquely_named = title_counts[tag.title] < 2
      end
    end

    def relatable_items
      @relatable_items ||= Artefact.relatable_items.to_a
    end

    def attempting_to_change_owning_app?(parameters_to_use)
      @artefact.persisted? &&
        parameters_to_use.include?('owning_app') &&
        parameters_to_use['owning_app'] != @artefact.owning_app
    end

    def redirect_to_show_if_need_met
      if params[:artefact] && params[:artefact][:need_id]
        artefact = Artefact.where(need_id: params[:artefact][:need_id]).first
        redirect_to artefact if artefact
      end
    end

    def find_artefact
      @artefact = Artefact.from_param(params[:id])
    end

    def build_artefact
      @artefact = Artefact.new(extract_parameters(params))
    end

    def extract_parameters(params)
      fields_to_update = Artefact.fields.keys + ['sections', 'primary_section', 'specialist_sectors']

      # TODO: Remove this variance
      parameters_to_use = params[:artefact] || params.slice(*fields_to_update)

      # Partly for legacy reasons, the API can receive live=true
      if live_param = parameters_to_use[:live]
        if ["true", true, "1"].include?(live_param)
          parameters_to_use[:state] = "live"
        end
      end

      # Convert nil tag fields to empty arrays if they're present
      Artefact.tag_types.each do |tag_type|
        if parameters_to_use.has_key?(tag_type)
          parameters_to_use[tag_type] ||= []
        end
      end

      # Strip out the empty submit option for sections
      ['sections', 'legacy_source_ids', 'specialist_sector_ids'].each do |param|
        param_value = parameters_to_use[param]
        param_value.reject!(&:blank?) if param_value
      end
      parameters_to_use
    end

    def build_actions
      # Construct a list of actions, with embedded diffs
      # The reason for appending the nil is so that the initial action is
      # included: the DiffEnabledAction class handles the case where the
      # previous action does not exist
      reverse_actions = @artefact.actions.reverse
      (reverse_actions + [nil]).each_cons(2).map { |action, previous|
        DiffEnabledAction.new(action, previous)
      }
    end

    def sort_column
      Artefact.fields.keys.include?(params[:sort]) ? params[:sort] : :name
    end

    def sort_direction
      %w[asc desc].include?(params[:direction]) ? params[:direction] : :asc
    end
end
