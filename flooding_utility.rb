require 'socket'
require 'link_state_packet'
require 'graph_builder'

class FloodingUtil
  
  attr_accessor :source_name, :source_ip, :link_state_packet, :link_state_table, :global_top, :port

  # ------------------------------------------------
  # Initialize the flooding util with the info
  # needed for the link state packet
  # ------------------------------------------------
  def initialize(source_name, source_ip, port_name, config_file)
    
    # Set source name field which marks
    # instance of node the flooding util 
    # is running on
    @source_name = source_name
    @source_ip = source_ip
    @port = port_name
    

    # Initialize link state table and insert
    # current source name and sequence number
    @link_state_table = Hash.new
    @link_state_table[@source_name] = 0

    # Construct initial graph 
    @global_top = GraphBuilder.new
    init_node = GraphNode.new(@source_name, @source_ip)
    @global_top.addNode(init_node)

    # Parse config file and set fields for
    # link state instance
    @link_state_packet = LinkStatePacket.new(sourceName, source_ip, 0)
    parse_config(config_file)

    # Add new neighbors to the global 
    # topology graph
    @link_state_packet.neighbors.keys.each do |(host, ip)|
    	neighbor = GraphNode.new(@host, @ip)
    	cost = @link_state_packet[[host, ip]]
    	@global_top.addNode(neighbor)
    	@global_top.addEdge(init_node, neighbor, cost)
    end

    # Flood network
    flood_neighbors(@link_state_packet)
  end

  # ------------------------------------------------
  # This utility method will be used to send the
  # current link state packet to its neighbors 
  # ------------------------------------------------
  def flood_neighbors(ls_packet)

    # Use tcp sockets to send out the link
    # state packet to all of its neighbors
    ls_packet.neighbors.keys.each do |neighbor|
        # Send packet 
        socket = TCPSocket.open(neighbor.source_ip, @port)
        socket.print(ls_packet.to_string)
    end      
  end

  # -----------------------------------------------
  # This utility method will be used to check
  # the given link state packet for validity
  # and will choose wether or not to discard the
  # given packet
  # -----------------------------------------------
  def check_link_state_packet(ls_packet)

    # Check first if the given link state
    # packets source node is in the table
    if @link_state_table[ls_packet.source_name] == nil
      @link_state_table[ls_packet.source_name] = ls_packet.seqNumb
      # Build graph
      ls_packet.neighbors.keys.each do |(host, ip)| 
        neighbor = GraphNode.new(@host, @ip)
        cost = ls_packet[[host, ip]]
        @global_top.addNode(neighbor)
        @global_top.addEdge(init_node, neighbor, cost)
      end
	    
    # If link state is already in the table check its seq numb
    # against the recieved link state packet if it did change 
    # we want to update the table and flood
    elsif @link_state_table[ls_packet.source_name] < ls_packet.seq_numb 
      # Update lsp and topology ls table and flood
      # Update link state table
      @link_state_table[ls_packet.source_name] = ls_packet.seq_numb

      # TODO - Update global topology graph 
      deadNode = @global_top.getNode(ls_packet.source_name)
      

      # Flood network with packe
      flood_neighbors(ls_packet)

    # If the recieved link state packet is in the table and
    # has the previously recorded sequence number we want
    # to drop the packet
    else        
       # Do nothing aka drop the packet
    end
  end

  # ---------------------------------------------
  # This utility method will parse out the
  # the information needed to create the link
  # state packets
  # ---------------------------------------------
  def parse_config(config_file)
    
    File.open(config_file, "r").readlines.each.do |line|
      nodes = line.split(',')

      # Check if the first node is listed in the line
      # is the current node being run on
      if nodes.first == @source_name
        # Check and see if neighbor is already in the hash
        if @link_state_packet.neighbors.has_key([nodes[2], nodes[3]])? == false
          @link_state_packet.neighbors[[nodes[2], nodes[3]]] = nodes[4]
        end 
       
      # Check if the third node listed in line is the
      # node being run on
      elsif nodes[2] == @source_name
        # Check and see if neighbor is already in the hash 
        if @link_state_packet.neighbors.has_key([nodes.first, nodes[1]])? == false
          @link_state_packet.neighbors[[nodes.first, nodes[1]]] = nodes[4]
        end 

      # Curent node has no neighbors  
      else 
        # Neighbors should be nil or empty 
      end
    end 
  end

  # --------------------------------------------
  # Determines if the local topology has changed
  # --------------------------------------------
  def has_changed(config_file)
  	# Temporary hash used to hold neighbors
  	# of current node parsed out from file
  	temp_neighbors = Hash.new

    # Parse the config file and look for the
    # information for the current node instance
    File.open(config_file, "r").readlines.each.do |line|
    	nodes = line.split(',')

    	# Look for current node in the first index of the line
    	if nodes.first == @source_name
    		temp_neighbors[[nodes[2], nodes[3]]] = nodes[4]

    	# Look for current node in the last index of the line
    	elsif nodes[2] == @source_name
    		temp_neighbors[[nodes.first, nodes[1]]] = nodes[4]

    	# Node not in current line	
    	else
    		# Do nothing
    	end
	end

	# Compare temp_neighbors parsed out to 
	# neighbors in current link state packet
	if  @link_state_packet.neighbors.keys.count == temp_neighbors.keys.count

		@link_state_packet.neighbors.keys.each do |(host, ip)|
			# Continue through loop if the neighbors in the 
			# temp_neighbor match up with the neighbors in the
			# current link state packet
			next if temp_neighbors.has_key?([host, ip]) && @link_state_packet.neighbors[[host, ip]] == temp_neighbors[[host, ip]]

			# Temp neighbors does not match link state
			# packet needs to be updated
			update_packet(temp_neighbors)

			return true
		end

		# If loop finishes without returning true the 
		# topology has not changed
		return false 
    end

    # Does not match current link state packet
    # needs to be updated
    update_packet(temp_neighbors)

    return true
  end

  # ----------------------------------------
  # This is a helper method used to update 
  # the current link state packet with new
  # params and flood it to the network
  # ----------------------------------------
  def update_packet(new_neighbors)

  	# Increase sequence number of link state packet
	@link_state_packet.seqNumb += 1

	# Update sequence number in link state table
	@link_state_table[@source_name] += 1

	# Update neighbors in link state packet
	@link_state_packet.neighbors = new_neighbors

	# Update global top

	# Flood network with updated packet
	flood_neighbors(@link_state_packet)

  end   
end


