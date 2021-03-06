class Mail < ActiveRecord::Base
  has_many :mail_state
  validate :allocate_route
  validate :no_overseas_mail
  validate :priority_validation

  validates :weight, numericality: { greater_than_or_equal_to: 0.1 }
  validates :volume, numericality: { greater_than_or_equal_to: 0.1 }

  before_save :format_routes
  before_save :format_prices
  before_save :format_costs
  after_save :create_states
  after_save :create_event
  self.attribute_names.reject{|a|["id","created_at","updated_at","sent_at","received_at","waiting_time","cost","price","routes_array","from_overseas"].include? a}.each do |a|
    validates_presence_of a
  end


  @routes = []
  @prices = []
  @costs  = []

  def to_hash
    hash = self.attributes.reject{|a| ["created_at","updated_at"].include? a}
    hash["states"] = self.mail_states.map(&:to_hash)
    hash["current_state"] = self.current_state.id
    hash
  end

  def created_at_formatted
    (self.created_at + 12.hours).to_s(:db)
  end

  def priority_string
    ["Standard", "High"][self.priority]
  end

  def origin
    begin
      Place.find(self.origin_id)
    rescue
      nil
    end
  end

  def destination
    begin
      Place.find(self.destination_id)
    rescue
      nil
    end
  end

  def sent_time
    if self.mail_states && self.mail_states.length >= 2
      if (Time.current + 12.hours) > self.mail_states[1].start_time
        return self.mail_states[1].start_time.to_s(:db)
      end
    end
    nil
  end

  def received_time
    if self.mail_states && self.mail_states.length >= 2
      if (Time.current + 12.hours) > self.mail_states.last.start_time
        return self.mail_states.last.start_time.to_s(:db)
      end
    end
    nil
  end

  def mail_states
    self.mail_state
  end

  def routes
    self.routes_array ||= ""
    @routes ||= self.routes_array.split(",")
    @routes.map {|r| MailRoute.find(r)}
  end

  def routes=(val) #Array of routes
    @routes = val
    self.prices = @routes.map{|r| self.from_overseas? ? 0 : r.price(self)}
    self.costs = @routes.map{|r| r.cost(self)}
    self.calculate_price_cost
    self.save
  end

  def mail_routes
    format_routes
    self.routes_array
  end

  def format_routes
    self.routes_array = routes.map{|r| r.id}.join(",")
  end

  def prices
    self.persisted_prices ||= ""
    @prices ||= self.persisted_prices.split(",").map(&:to_f)
  end

  def prices= (prices)
    @prices = prices
    format_prices
  end

  def format_prices
    self.persisted_prices = @prices.join(",")
  end

  def costs
    self.persisted_costs ||= ""
    @costs ||= self.persisted_costs.split(",").map(&:to_f)
  end

  def costs= (costs)
    @costs = costs
    format_costs
  end

  def format_costs
    self.persisted_costs = @costs.join(",")
  end

  def places_exist
    #Do we have and origin and destination?
      have = true
      if self.origin.nil?
        errors.add(:origin_id, "That origin does not exist.")
        have = false
      end

      if self.destination.nil?
        errors.add(:destination_id, "That destination does not exist.")
        have = false
      end

      if !have
        return false
      end
      true
  end

  def no_overseas_mail
    if !self.origin.try(:new_zealand?)
      errors.add(:origin_id, "all mail must originate from within New Zealand.")
    end
  end

  def allocate_route
    if @routes.blank? && self.weight && self.volume
      
      #Validate the places exist
      if !places_exist
        return false
      end      
      
      if self.origin_id == self.destination_id
        errors.add(:destination_id, "Can't have same destination as origin") and return
      end


      optimum_wv_goal = optimum_wv_a_star
      if(optimum_wv_goal.nil?)
        errors.add(:base, "There is no route from #{self.origin} to #{self.destination}")
        return false
      end
      

      restrictive_goal = restrictive_a_star

      # Collect route in to array
      if restrictive_goal.nil?
        errors.add(:base, "The maximum weight for a route from #{self.origin} to #{self.destination} is #{optimum_wv_goal.lowest_weight_to_here}kg")
        errors.add(:base, "The maximum volume for a route from #{self.origin} to #{self.destination} is #{optimum_wv_goal.lowest_volume_to_here}m3")

        return false
      end
      current = restrictive_goal
      route = []
      until current.path_from.nil?
        route.push current.path_from_route
        current = current.path_from
      end
      route = route.reverse
      self.routes = route
    end
  end

  def restrictive_a_star
    goal = nil
    #Reset all places to visted = false
    all_places = Place.all
    all_places.each {|p| p.visited = false}
    
    #Find the routes that begin with the mail's origin 
    all_routes = MailRoute.all 
    routes_im_dealing_with = all_routes.select{|route| route.origin_id == self.origin_id && self.weight <= route.maximum_weight && self.volume <= route.maximum_volume && route.active?}

    #initialise priority queue with appropriate routes using the heuristic associate with priority. 0 = low = price, 1 = high = speed
    start = all_places.select{|place| place.id == self.origin_id}.first
    pQueue = PQueue.new([PQueueTuple.new(start, nil, nil, 0)]){|a,b| a.cost_to_here < b.cost_to_here}

    

    while !pQueue.empty? do
      tuple = pQueue.pop
      if(!tuple.start.visited?)
        tuple.start.visited = true
        tuple.start.path_from = tuple.from
        tuple.start.path_from_route = tuple.from_route

        if(tuple.start.id == self.destination_id)

          goal = tuple.start
        end

        routes_im_dealing_with = all_routes.select{|route| route.origin_id == tuple.start.id  && self.weight <= route.maximum_weight && self.volume <= route.maximum_volume && route.active? }
        routes_im_dealing_with.each do |route|
          destination = all_places.select{|place| place.id == route.destination_id}.first
          if(!destination.visited?)
            if(self.priority == 0)
              route_cost = route.price(self)
            else
              route_cost = route.next_receival
            end
            cost_to_neigh = tuple.cost_to_here + route_cost
            pQueue.push(PQueueTuple.new(destination, tuple.start, route, cost_to_neigh))
          end
        end
      end        
    end 
    goal
  end

  def optimum_wv_a_star
    goal = nil
    #Reset all places to visted = false
    all_places = Place.all
    all_places.each {|p| p.visited = false}
    
    #Find the routes that begin with the mail's origin 
    all_routes = MailRoute.all 
    routes_im_dealing_with = all_routes.select{|route| route.origin_id == self.origin_id && route.active?}

    #initialise priority queue with appropriate routes using the heuristic associate with priority. 0 = low = price, 1 = high = speed
    start = all_places.select{|place| place.id == self.origin_id}.first
    pQueue = PQueue.new([PQueueTuple.new(start, nil, nil, 0)]){|a,b| a.cost_compared_to(b) < b.cost_compared_to(a)}

    

    while !pQueue.empty? do
      tuple = pQueue.pop

      if(!tuple.start.visited?)
        tuple.start.visited = true
        tuple.start.path_from = tuple.from
        tuple.start.path_from_route = tuple.from_route

        if(!tuple.from_route.nil?)
          route_from = MailRoute.find(tuple.from_route)
          if(!tuple.from.nil?)            
            tuple.start.lowest_weight_to_here = [route_from.maximum_weight, tuple.from.lowest_weight_to_here].min
            tuple.start.lowest_volume_to_here = [route_from.maximum_volume, tuple.from.lowest_volume_to_here].min
          else
            tuple.start.lowest_weight_to_here = route_from.maximum_weight
            tuple.start.lowest_volume_to_here = route_from.maximum_volume
          end
        else
          tuple.start.lowest_weight_to_here = 999999
          tuple.start.lowest_volume_to_here = 999999
        end

        if(tuple.start.id == self.destination_id)
            goal = tuple.start
        end

        routes_im_dealing_with = all_routes.select{|route| route.origin_id == tuple.start.id && route.active? }
        routes_im_dealing_with.each do |route|
          destination = all_places.select{|place| place.id == route.destination_id}.first
          if(!destination.visited?)
            
          route_cost = (self.weight < route.maximum_weight ? 0 : self.weight - route.maximum_weight)+(self.volume < route.maximum_volume ? 0 : self.volume - route.maximum_volume)
          
          cost_to_neigh = [tuple.cost_to_here, route_cost].max
          pQueue.push(PQueueTuple.new(destination, tuple.start, route, cost_to_neigh))
          end
        end
      end        
    end 
    goal
  end


  def current_state
    self.mail_state.select{|state| (Time.now + 12.hours) > state.start_time}.last
  end

  def current_location
    if self.routes.length > 0
      if current_state.routing_step >= self.routes.length
        return self.routes.last.destination
      end

      if current_state.routing_step < 0
        return nil
      end

      self.routes[current_state.routing_step].origin
    end
  end

  def calculate_price_cost
    self.cost = self.costs.sum
    self.price = self.prices.sum
  end

  def still_needs_route? (route)
    id = route.id
    states_requiring = self.mail_states.select{|s| s.route_id == id}.map(&:id)
    last_state = states_requiring.max
    unless last_state.nil?
      return true if self.current_state.id < last_state
    end
    false
  end

  private

  def priority_validation
    unless [0,1].include? self.priority
      errors.add(:priority, "must be standard or high priority")
    end
  end
  def from_overseas_present
    if self.from_overseas.nil?
      errors.add(:from_overseas, "must select yes or no")
    end
  end

  def create_states
    i = 0
    current_time = (Time.now + 12.hours).to_i
    MailState.where(mail_id: self.id).each{|s|s.delete}
    self.routes.each do |route|
      #Waiting state until departure
      start_time = current_time
      end_time = start_time + (route.next_receival_from_time(start_time) - (route.duration*60))
      MailState.create({
        current_location_id: route.origin_id,
        next_destination_id: route.origin_id,
        route_id: route.id,
        routing_step: i,
        state_int: 0,
        mail_id: self.id,
        start_time: Time.at(start_time),
        end_time: Time.at(end_time)
      })
      current_time = end_time
      start_time = current_time
      end_time = start_time + route.duration * 60
      #In transit
      MailState.create({
        current_location_id: route.origin_id,
        next_destination_id: route.destination_id,
        route_id: route.id,
        routing_step: -1,
        state_int: 1,
        mail_id: self.id,
        start_time: Time.at(start_time),
        end_time: Time.at(end_time)
      })
      i += 1
      current_time = end_time
      start_time = current_time
      #Are we done yet?
      if route.destination_id == self.destination_id
        MailState.create({
          current_location_id: route.destination_id,
          next_destination_id: route.destination_id,
          route_id: route.id,
          routing_step: i,
          state_int: 2,
          mail_id: self.id,
          start_time: Time.at(start_time),
          end_time: nil
        })
      end
    end
  end

  def create_event
    business_event = BusinessEvent.new
    business_event.set_mail_values(self)
    business_event.save
  end
end
