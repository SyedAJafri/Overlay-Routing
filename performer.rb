require 'base64'

require_relative 'dijkstra_executor.rb'

#Handles commands from the user e.g. TRACEROUTE, CHECKSTABLE, PING 
class Performer


	#returns packets to forward
	def self.perform_traceroute(main_processor, destination_name)

		if destination_name.nil?
			throw :invalid_argument
		end

		#TODO handle timeout 

		payload = Hash.new

		#Fill in initial trace route hopcount of 0 the hostname and time to get to node is 0
		payload['data'] = "0 #{main_processor.source_hostname} 0\n" #TODO hostname
		#Starting hop time in milliseconds
		payload["last_hop_time"] = (main_processor.node_time.to_f * 1000).ceil

		control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, destination_name, nil, 0, "TRACEROUTE", payload,
				main_processor.node_time)

		control_message_packet 
	end 

	#returns packets to forward
	def self.perform_ftp(main_processor, destination_name, file_name, fpath)

		if destination_name.nil? or file_name.nil? or fpath.nil?
			throw :invalid_argument
		end

		payload = Hash.new

		#destination path
		payload['FPATH'] = fpath
		payload['file_name'] = file_name

		#TODO handle errors with binread
		file_contents = IO.binread(file_name) #Reads as ASCII-8BIT
		file_contents_encoded = Base64.encode64(file_contents) #US-ASCII

		payload['size'] = file_contents.length

		#Fill in initial trace route hopcount of 0 the hostname and time to get to node is 0
		payload['data'] = file_contents_encoded

		control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, destination_name, nil, 0, "FTP", payload,
				main_processor.node_time)

		control_message_packet 
	end

	# ------------------------------------------------------------
	# Constructs the initial packet that'll be sent to 
	# the given destination hostname with the provided message.
	# @param main_processor Used to get source information.
	# @param destination_name End destination of packet.
	# @param message String containing message to send.
	# ------------------------------------------------------------
	def self.perform_send_message(main_processor, destination_name, message)
		if main_processor.nil? or destination_name.nil? or message.nil?
			throw :invalid_argument
		end

		# add message data into the payload and message size
		payload = Hash.new
		payload["message"] = message
		payload["size"] = message.size

		control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, destination_name, nil, 0, "SND_MSG", payload, main_processor.node_time)

		control_message_packet
	end

	# -----------------------------------------------------------
	# Construct initial packet that will be sent to the given
	# nodes in the node list and the nodes will be added to the 
	# subscription group 
	# -----------------------------------------------------------
	def self.perform_advertise(main_processor, unique_id, node_list) 
		if main_processor.nil? or unique_id.nil? or node_list.nil?
			throw :invalid_argument
		end

		payload = Hash.new

		# Check if the only node in the node list is self
		if node_list.length == 1 && main_processor.source_hostname.eql?(node_list[0])
			main_processor.subscription_table[unique_id] = node_list
			puts "1 NODE #{node_list[0]} SUBSCRIBED TO #{unique_id}"
			reutrn nil

		# add unique subscription id and 
		# rest of node list to payload
		payload["unique_id"] = unique_id

		# Send node list 
		payload["node_list"] = node_list

		# Use visited nodes list to determine
		# which nodes in the nodes list has
		# already been visited
		payload["visited"] = Array.new

		# Check if the current node should
		# be part of the subscription
		# Add it to table and visited if it is
		if node_list.include?(main_processor.source_hostname)
			payload["visited"] << main_processor.source_hostname

			# Make a node a destination
			if node_list[0].strip.eql?(main_processor.source_hostname)
				first_destination = node_list[1].strip
			else
				first_destination = node_list[0].strip
			end

		# Else make the first node in the node list the first
		# destination
		else
			first_destination = node_list[0].strip
		end

		# Set the previous, next, and current nodes
		# in the payload
		payload["prev"] = nil
		payload["current"] = main_processor.source_hostname
		payload["next"] = first_destination

		control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, first_destination, nil, 0, "ADVERTISE", payload, main_processor.node_time)

		control_message_packet
	end

	# -------------------------------------------------------------
	# Creates the initial packet for a clocksync to be
	# performed. Destination name is the node that the time
	# is being retrieved from.
	# @param main_processor Used to grab time, source, etc.
	# @param destination_name Specifies the destination hostname.
	# -------------------------------------------------------------
	def self.perform_clocksync(main_processor, destination_name)
		if main_processor.nil? or destination_name.nil?
			throw :invalid_argument
		end

		#create control message packet
		control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, destination_name, nil, 0, "CLOCKSYNC", Hash.new, main_processor.node_time)

		control_message_packet
	end

	# -------------------------------------------------------------------
	# Return the initial control message packet to be forwarded to the 
	# destination included with a ping command
	# -------------------------------------------------------------------
	def self.perform_ping(main_processor, destination_name, seq_id, unique_id)
		if destination_name.nil? or seq_id.nil? or unique_id.nil?
			throw :invalid_argument

		payload = Hash.new

		# Start the sequence id at 0 initially
		payload['SEQ_ID'] = seq_id

		# Mark it with its unique_id
		payload['unique_id'] = [unique_id, 'PING']

		control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
			main_processor.source_ip, destination_name, nil, 0, "PING", payload,
			main_processor.node_time)

		control_message_packet
	end 

	# --------------------------------------------------------------
	# Perform the DUMPTABLE hook by going through the routing
	# table's entries and writing the source host ip, destination
	# ip, next hop, and total distance from source to destination
	# to a .csv file.
	# @param main_processor Used to grab routing table.
	# @param filename Specifies the name of the file to create.
	# --------------------------------------------------------------
	def self.perform_dumptable(main_processor, filename)
		filename = filename + ".csv" if filename !~ /.csv/

		# creating the file and writing routing table information
		File.open(filename, "w+") { |file|
			if main_processor.routing_table != nil
				main_processor.routing_table.each { |destination, info|
					file.puts("#{main_processor.source_hostname},#{info.destination.ip},#{info.next_hop.ip},#{info.distance}")
				}
			end

			file.close
		}
	end

	# -----------------------------------------------------------------------
	# Performs the FORCEUPDATE command by calling the flooding
	# utility to determine if the current node's local topology
	# has changed. If it changed, the flooding utility sends the
	# new link state packet out and reconstruct the global topology
	# graph. Then, the routing table is updated. If the link state
	# packet didn't change this function will do nothing.
	# @param main_processor Used to get flooding util, routing table, etc.
	# -----------------------------------------------------------------------
	def self.perform_forceupdate(main_processor)
		packet_changed = main_processor.flooding_utility.has_changed(main_processor.weights_config_filepath)

		if (packet_changed)
		 	main_processor.routing_table_updating = true
			main_processor.routing_table = DijkstraExecutor.routing_table(main_processor.flooding_utility.global_top, main_processor.source_hostname)
			main_processor.routing_table_updating = false

			$log.debug "Finished updating node's (#{main_processor.source_hostname}) routing table and global topology graph."
		else
			$log.debug "Node's (#{main_processor.source_hostname}) local topology did not change."
		end
	end

	# -------------------------------------------------------------------
	# Performs the CHECKSTABLE command by determining if the
	# routing table is currently being updated. If it is, 'no' is
	# printed specifying that the node is unstable. Otherwise,
	# 'yes' is printed showing that the node is stable.
	# @param main_processor Used to check if routing table is updating.
	# -------------------------------------------------------------------
	def self.perform_checkstable(main_processor)
		if (main_processor.routing_table_updating)
			$stdout.puts("no")
		else
			$stdout.puts("yes")
		end
	end

	# ----------------------------------------------------------------
	# Performs the SHUTDOWN command...
	# ----------------------------------------------------------------
	def self.perform_shutdown(main_processor)
		# shutdown all open sockets
		# print current buffer information
	end
end
