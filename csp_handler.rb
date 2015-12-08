# -*- coding: utf-8 -*-
require 'base64'
require 'openssl'

require_relative 'control_msg_packet.rb'

#Handles Control Message Packets (CMPs) from the CMP queue
#Functions might return packets to add to forward_queue
class ControlMessageHandler

	#TODO delete and use actual encryption
	def self.decrypt(key, plain)
		return plain
	end

	def self.handle(main_processor, control_message_packet, optional_args=Hash.new)
		$log.debug "Processing #{control_message_packet.inspect}"
		payload = control_message_packet.payload

		cmp_type = control_message_packet.type

		if cmp_type.eql? "TRACEROUTE"
			self.handle_traceroute_cmp(main_processor, control_message_packet, optional_args)
		elsif cmp_type.eql? "FTP"
			self.handle_ftp_cmp(main_processor, control_message_packet, optional_args)
		elsif cmp_type.eql? "PING"
			self.handle_ping_cmp(main_processor, control_message_packet, optional_args)
		elsif cmp_type.eql? "SND_MSG"
			self.handle_send_message_cmp(main_processor, control_message_packet, optional_args)
		elsif cmp_type.eql? "TOR"
			self.handle_tor(main_processor, control_message_packet, optional_args)
        elsif cmp_type.eql? "ADVERTISE"
            self.handle_advertise(main_processor, control_message_packet, optional_args)
		elsif cmp_type.eql? "CLOCKSYNC"
			self.handle_clocksync_cmp(main_processor, control_message_packet, optional_args)
		elsif cmp_type.eql? "POST"
			self.handle_post_cmp(main_processor, control_message_packet, optional_args)
		else
			$log.warn "Control Message Type: #{cmp_type} not handled"
		end	
	end


	def self.handle_tor(main_processor, control_message_packet, optional_args)

		tor_payload_encrypted = Base64.decode64(control_message_packet.payload["TOR"])

		#tor_payload_encrypted = JSON.parse control_message_packet.payload["TOR"]

		#Get symmetric key and iv from uppermost layer using RSA private key
		upper_layer_key = main_processor.private_key.private_decrypt(Base64.decode64(control_message_packet.encryption['key']))
		upper_layer_iv = main_processor.private_key.private_decrypt(Base64.decode64(control_message_packet.encryption['iv']))

		decipher = OpenSSL::Cipher::AES128.new(:CBC)
		decipher.decrypt
		decipher.key = upper_layer_key
		decipher.iv = upper_layer_iv

		#decrypt with own RSA private key

		tor_payload = decipher.update(tor_payload_encrypted) + decipher.final
		tor_payload = JSON.parse tor_payload

		$log.debug "onions: \"#{tor_payload.inspect}\""

		#payload = JSON.parse payload
		if tor_payload["complete"] == true
			#Arrived at destination
			puts "Received onion message: \"#{tor_payload["message"]}\""
		else
			#Current hop is intermediate hop
			#Unwrap lower cmp and forward
			csp_str = tor_payload["next_cmp"]
			$log.debug "next_cmp: #{csp_str.inspect}"
			csp = ControlMessagePacket.from_json_hash JSON.parse csp_str
			$log.debug "TOR unwrapped and forwarding to #{csp.destination_name} #{csp.inspect}"
			return csp, {}
		end
		

	end

	#Handle a traceroute message 
	def self.handle_traceroute_cmp(main_processor, control_message_packet, optional_args)
		#A traceroute message is completed when payload["complete"] is true
		#and payload["original_source_name"] == main_processor.source_hostname
		#In that case payload["traceroute_data"] will have our data

		#TODO handle timeouts correctly talk to Tyler
		

		payload = control_message_packet.payload
		
		$log.debug "payload #{payload}:#{payload.class}"

		if payload["failure"]

			if control_message_packet.destination_name.eql? main_processor.source_hostname
				$log.debug "Time passed since source #{(main_processor.node_time.to_f ) - control_message_packet.time_sent}"
				$log.debug "Failed Traceroute arrived back #{payload.inspect}"
				puts "#{main_processor.ping_timeout} ON #{payload["HOPCOUNT"]}"
			else
				#Else data is complete. It is just heading back to original source
				return control_message_packet, {}
			end
		elsif payload["complete"]
			if control_message_packet.destination_name.eql? main_processor.source_hostname

				$log.debug "Traceroute timeout #{(main_processor.node_time.to_f ) - control_message_packet.time_sent}"
				if main_processor.ping_timeout <= (main_processor.node_time.to_f ) - control_message_packet.time_sent
					$log.debug "Failed Traceroute arrived back #{payload.inspect}"
					puts "#{main_processor.ping_timeout} ON #{payload["HOPCOUNT"]}"
				else
					#TODO additional timeout check here
					$log.debug "Traceroute arrived back #{payload.inspect}"
					puts payload["data"]
				end
			else
				#Else data is complete. It is just heading back to original source
				return control_message_packet, {}
			end
			
		else

			$log.debug "Time passed since source #{(main_processor.node_time.to_f ) - control_message_packet.time_sent}"
			#If the timeout is less than or equal to the current time - the time the packet was sent give a failure
			if main_processor.ping_timeout <= (main_processor.node_time.to_f ) - control_message_packet.time_sent
				$log.debug "Traceroute timeout #{(main_processor.node_time.to_f ) - control_message_packet.time_sent}"
				#Update hopcount
				payload["HOPCOUNT"] = payload["HOPCOUNT"].to_i + 1

				payload["data"] = "" # clear payload
				payload["failure"] = true

				#send back to host early
				control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "TRACEROUTE", payload, control_message_packet.time_sent)

				control_message_packet.payload = payload
				return control_message_packet, {}
			end

			#Get difference between last hop time and current time in milliseconds
			hop_time = (main_processor.node_time * 1000).to_i - payload["last_hop_time"].to_i
			hop_time.ceil

			#Update hop time on payload in ms
			payload["last_hop_time"] = (main_processor.node_time.to_f * 1000).ceil

			#Update hopcount
			payload["HOPCOUNT"] = payload["HOPCOUNT"].to_i + 1

			payload["data"] += "#{payload["HOPCOUNT"]} #{main_processor.source_hostname} #{hop_time}\n"



			#Trace Route has reached destination. Send a new packet to original
			#source with the same data but marked as completed
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				payload["complete"] = true
				#preserve original time sent
				control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "TRACEROUTE", payload, control_message_packet.time_sent)

			end

			control_message_packet.payload = payload
			return control_message_packet, {}
		
		end

	end

	#Handle a ftp message 
	def self.handle_ftp_cmp(main_processor, control_message_packet, optional_args)
		#TODO handle fragmented packets later
		#TODO handle partial data received

		payload = control_message_packet.payload

		unless control_message_packet.destination_name.eql? main_processor.source_hostname
			#packet is not for this node and we have nothing to add. Just forward it along.
			return control_message_packet, {}
		end

		if optional_args["fragmentation_failure"]

			matches = control_message_packet.payload.match(/.*data\":\"(.*)/)
			#Unable to reassemble fragmented packet
			
			puts "FTP: ERROR: #{control_message_packet.source_name} --> #{optional_args["FPATH"]}/#{optional_args["file_name"]}"


			payload = Hash.new
			payload["complete"] = false
			payload["failure"] = true
			
			
			payload["file_name"] = optional_args["file_name"]
			payload["FPATH"] = optional_args["FPATH"]


			payload = Hash.new

			if matches.length.eql? 2
				payload["bytes_written"] = matches[1].delete("\"").delete("}").size
			else
				#Fragment cutoff before data received
				payload["bytes_written"] = 0 
			end

			$log.debug "bytes_written: #{payload["bytes_written"]}"

			#Create new control message packet to send back to source but preserve original node time
			control_message_packet = ControlMessagePacket.new(control_message_packet.destination_name,
			control_message_packet.destination_ip, control_message_packet.source_name,
			control_message_packet.source_ip, 0, "FTP", payload, control_message_packet.time_sent)
			return control_message_packet, {}
		end 

		if payload["failure"]
			$stderr.puts "FTP: ERROR: #{payload["file_name"]} --> #{control_message_packet.source_name} INTERRUPTED AFTER #{payload["bytes_written"]}"
		elsif payload["complete"]
			#TODO handle Returned FTP complete. Packet back at source to handle
			$log.debug "TODO FTP packet arrived back #{payload.inspect}"

			#Calculate seconds since initial FTP packet
			time = main_processor.node_time.to_f - control_message_packet.time_sent
			time = time.ceil

			speed = 0
			begin
				speed = (payload["size"].to_i / time).floor
			rescue Exception => e
				throw e #TODO delete
				#probably a 0 as time just use 0 as the speed then
			end

			$stderr.puts "FTP: #{payload["file_name"]} --> #{control_message_packet.source_name} in #{time} at #{speed}"
			return nil, {} # no packet to forward
		else
			begin
				file_path = payload["FPATH"] + '/' + payload["file_name"]

				file_exists = File.exists? file_path

				begin
					file = File.open(file_path, "w+b:ASCII-8BIT")
					file.print Base64.decode64(payload["data"])
				rescue Exception => e
					#if file existed before attempted write don't delete
					unless file_exists
						File.delete file_path
						$log.info "deleted #{file_path} since FTP failed"
					end
					throw e
				end

				if file
					bytes_written = file.size
				else
					bytes_written = 0
				end

				file.close

				unless bytes_written.eql? payload["size"]
					#TODO I don't think this can happen when we do fragmentation
					throw "FTP size mismatch. Payload size: #{payload["size"]} != bytes_written: #{bytes_written}"
				end

				payload["complete"] = true
				payload.delete "data" #clear data

				#Create new control message packet to send back to source but preserve original node time
				control_message_packet = ControlMessagePacket.new(control_message_packet.destination_name,
				control_message_packet.destination_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "FTP", payload, control_message_packet.time_sent)

				$stderr.puts "FTP: #{control_message_packet.source_name} --> #{file_path}"

				control_message_packet.payload = payload
				return control_message_packet, {}

			rescue Exception => e

				$log.debug "FTP Exception #{e.inspect}"
				$stderr.puts "FTP: ERROR: #{control_message_packet.source_name} --> #{file_path}"

				payload["complete"] = false
				payload["failure"] = true
				payload.delete "data" #clear data

				payload["bytes_written"] = 0

				#Create new control message packet to send back to source but preserve original node time
				control_message_packet = ControlMessagePacket.new(control_message_packet.destination_name,
				control_message_packet.destination_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "FTP", payload, control_message_packet.time_sent)

				return control_message_packet, {}
			end
		end
	end

	# ----------------------------------------------------------
	# Reconstructs the command message packet for ping
	# commands. Returns the changed packet if it still needs
	# to be forwards, otherwise it returns nil.
	# ----------------------------------------------------------
	def self.handle_ping_cmp(main_processor, control_message_packet, optional_args)
		
		# Set local variable payload to access the
		# control message packet's payload quicker 
		payload = control_message_packet.payload

		# Make sure this packet has not timed out
		# Check if we are at the correct node and if the packet has already timed
		# out. Then check the notification variable
		if main_processor.timeout_table.has_key?(payload['unique_id']) && has_timed_out(main_processor, control_message_packet.time_sent)
			# Check if there has been a notification for a timeout
			if !main_processor.timeout_table[payload['unique_id']][1]	
				main_processor.timeout_table[payload['unique_id']][1] = true
				$stderr.puts "PING ERROR: HOST UNREACHABLE"
			end

			return nil
		end 

		unless control_message_packet.destination_name.eql? main_processor.source_hostname
			#packet is not for this node and we have nothing to add. Just forward it along.
			return control_message_packet, {}
		end

		# First check if the packet is complete
		if payload["complete"]

			# Then check if the packet is at its destination
			# If it is at its destination then the packet has made its
			# round trip.
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				$stderr.puts "#{payload['SEQ_ID']} #{control_message_packet.source_name} #{main_processor.node_time - control_message_packet.time_sent}"
			else
				# Continue to travel to next node
				return control_message_packet, {}
			end

		# Packet is at its destination but is not complete must 
		# set complete to true and return to sender	
		elsif control_message_packet.destination_name.eql? main_processor.source_hostname
			payload["complete"] = true

			# Create new control message to send back to source.
			# We must also preserve the time sent to calculate the 
			# round trip time
			control_message_packet = ControlMessagePacket.new(control_message_packet.destination_name,
				control_message_packet.destination_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "PING", payload, control_message_packet.time_sent)

			return control_message_packet, {}

		end
	end

	# -----------------------------------------------------------
	# Reconstructs a control message packet according to the
	# current node that it is on. Returns nil if the packet has
	# gotten back to its origin, otherwise it returns the
	# changed control message packet.
	# -----------------------------------------------------------
	def self.handle_send_message_cmp(main_processor, control_message_packet, optional_args)
		payload = control_message_packet.payload
		if payload["complete"]
			# if the packet has made a round trip, determine if it was a success or
			# not and print the corresponding messages
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				if payload["failure"]
					$log.debug "SendMessage got back to the source but failed to fully send to recipient, payload: #{payload.inspect}"
					$stderr.puts "SENDMSG ERROR: #{control_message_packet.source_name} UNREACHABLE"
				end
			else
				# hasn't gotten back to source yet, so return packet so that it'll be forwarded
				return control_message_packet, {}
			end
		else
			# arrived at the destination, send back to source node so that the source can 
			# confirm if the message was fully received by inspecting the presence of
			# the failure key in the payload hash
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				if payload["size"].to_i != payload["message"].size
					payload["failure"] = true
				else
					$log.debug "SendMessage got to the destination successfully, payload: #{payload.inspect}"
					$stderr.puts("SENDMSG: #{control_message_packet.source_name} --> " + payload["message"])
				end

				payload["complete"] = true
				control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "SND_MSG", payload, main_processor.node_time)
			end

			control_message_packet.payload = payload
			return control_message_packet, {}
		end
	end

	# ------------------------------------------------------------------------------
	# This method will be used to handle advertise control message packets.
	# It will propagate the message on to the next node it needs to go to while
	# keeping track of the node it need to travel to next and the one it came 
	# from. Each node will contain a table to keep track of all the nodes in the
	# subscription. The key is the subscription id and the value is the list of
	# nodes in the subscription.
	# ------------------------------------------------------------------------------
	def self.handle_advertise(main_processor, control_message_packet, optional_args)
		destination_count = 0
		payload = control_message_packet.payload
		unique_id = payload["unique_id"]
		node_list = payload["node_list"]

		# Want to add the subscription id to every node traveled to
		# if it is not already recorded in its table
		if !main_processor.subscription_table.has_key?(unique_id)
			main_processor.subscription_table[unique_id] = node_list
		end

		unless control_message_packet.destination_name.eql? main_processor.source_hostname || node_list.include?(main_processor.source_hostname)
			# This node is not in the node list. Foward the packet along
			# without any processing
			return control_message_packet, {}
		end 

		# Node is on its way back to the source. This is
		# where the outputting will be done based on the 
		# path that was constructed in the visited array
		if payload["complete"]

			# If we are at the destination then we know we have
			# made the round trip. Need to determine if the
			# final destination is part of the subscription

			# First check if we are at the destination
			if control_message_packet.destination_name.eql?(payload["source"]) && payload["source"].eql?(main_processor.source_hostname)
				# Output and finish passing along of packet
				num_nodes = payload["visited"].length
				visited = payload["visited"]

				$stderr.puts "#{num_nodes} NODES #{node_list.to_s} SUBSCRIBED TO #{unique_id}"

				return nil

			# If we are not at a destination we want to write
			# to standard error the correct output and forward the 
			# packet along
			else
				# Check if we are at a node in the node list
				if node_list.include?(main_processor.source_hostname)
					# Grad index of node in visited list
					current_index = payload["visited"].index(main_processor.source_hostname)
					control_message_packet = nil 

					# Wrap around to end of visited list if the 
					# current index - 1 is negative. Reached end of 
					# visited list
					if current_index - 1 < 0
						prev = payload["visited"][payload["visited"].length - 1] 

						#
						control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
							main_processor.source_ip, payload["source"], nil, 0, "ADVERTISE", payload, main_processor.node_time)
					else
						prev = payload["visited"][current_index - 1]

						control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
							main_processor.source_ip, prev, nil, 0, "ADVERTISE", payload, main_processor.node_time)
					end

					# Next node will be next in the visited list
					next_node = payload["visited"][current_index + 1]


					# Output and foward packet along
					$stderr.puts "ADVERTISE: #{prev} --> #{next_node}"
					return control_message_packet, {}
				else
					# Forward packet along
					return control_message_packet, {}
				end
			end

		else
			# Node is on its first traversal
			# First check if the node is at its destination and 
			# if the packet has visited all of the nodes in the
			# node list

			# Add node to visited. Check to make sure it is not
			# already in the visited array. Do not want duplicates
			payload["visited"] << main_processor.source_hostname if !payload["visited"].include?(main_processor.source_hostname)

			# At a destination 
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				# Made it to the end of first trip ready to turn
				# back to source
				if payload["visited"].length.eql? node_list.length
					
					payload["complete"] = true

					# Previous will be the second to last node in the
					# visited list and next will be the first node visited
					# Note these are only the nodes displayed. Packet may
					# be traveling somewhere outside of the subscription
					prev = payload["visited"][payload["visited"].length - 2]
					next_node = payload["visited"][0]

					control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
						main_processor.source_ip, prev, nil, 0, "ADVERTISE", payload, main_processor.node_time)

					# Output to stderr
					$stderr.puts "ADVERTISE: #{prev} --> #{next_node}"

					return control_message_packet

				# Did not visit every node. Need to pick another
				# destination to travel to that has not already 
				# been visited
				else
					# Find node that has not already been visited
					until !payload["node_list"][destination_count].eql?(main_processor.source_hostname) && !(payload["visited"].include?(payload["node_list"][destination_count]))
						destination_count += 1
					end

					# Create new control message packet to foward with new destination 
					control_message_packet = ControlMessagePacket.new(control_message_packet.source_name,
						control_message_packet.source_ip, payload["node_list"][destination_count], 
						nil, 0, "ADVERTISE", payload, main_processor.node_time)

					# Foward packet
					return control_message_packet, {}
				end

			# Not at a destination but in the node list.
			# Foward packet along
			else
				return control_message_packet, {}
			end
		end
	end

	# -------------------------------------------------------------------
	# Reconstructs a POST control message packet depending on the
	# the current node that the packet is on. Returns nil if the packet
	# has gotten back to its origin, otherwise it returns the newly
	# modified control message packet or the original if a node is
	# just forwarding the packet.
	# -------------------------------------------------------------------
	def self.handle_post_cmp(main_processor, control_message_packet, optional_args)
		payload = control_message_packet.payload
		received_nodes = payload["received_nodes"]
		subscribed_nodes = payload["subscribed_nodes"]

		# checking if all subscribed nodes have been hit
		if payload["complete"]
			if control_message_packet.destination_name.eql? main_processor.source_hostname

				# check if all nodes received the message or not
				if received_nodes.size == main_processor.subscription_table[payload["subscription_id"]].size
					$stderr.puts("POST #{payload['subscription_id']} DELIVERED TO #{received_nodes.size}")
				else
					$stderr.puts("POST FAILURE: #{payload['subscription_id']} NODES #{received_nodes.to_s} FAILED TO RECEIVE MESSAGE")
				end

				return nil, {}
			end

			return control_message_packet, {}
		else
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				$stderr.puts("SENDMSG: #{control_message_packet.source_name} --> #{payload['message']}")

				# add this host to the received nodes
				received_nodes << main_processor.source_hostname

				# determine to send message back to source or
				# to the next subscribed node
				if subscribed_nodes.empty?
					payload["complete"] = true
					control_message_packet.destination_name = control_message_packet.source_name
					control_message_packet.source_name = main_processor.source_hostname
					control_message_packet.source_ip = main_processor.source_ip
				else
					control_message_packet.destination_name = subscribed_nodes.pop
				end
			end

			control_message_packet.payload = payload
			return control_message_packet, {}
		end
	end

	# -----------------------------------------------------------
	# Reconstructs a control message packet according to the
	# current node that it is on. Returns nil if the packet has
	# gotten back to its origin, otherwise it returns the
	# changed control message packet. Saves node time in
	# payload and sends back to source if at destination.
	# -----------------------------------------------------------
	def self.handle_clocksync_cmp(main_processor, control_message_packet, optional_args)
		payload = control_message_packet.payload

		#only print if command started by user and not main_processor.recurring_clocksync
		user_initiated = payload["user_initiated"]
		$log.debug payload.inspect

		if payload["destination_time"]
			# determine if packet has made a round trip
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				$log.debug "CLOCKSYNC has made a full round trip."
				round_trip_time = (Time.at(main_processor.node_time) - Time.at(control_message_packet.time_sent)) / 2

				# determine if this node's time needs to be synced 
				needs_syncing = Time.at(main_processor.node_time) <=> Time.at(payload["destination_time"] + round_trip_time)
				if needs_syncing == -1
					delta = (payload["destination_time"] + round_trip_time - main_processor.node_time)
					main_processor.node_time = payload["destination_time"] + round_trip_time

					$log.debug "Node's (#{main_processor.source_hostname}) time is behind node (#{control_message_packet.source_name}) and is being synced."
					$stderr.puts Time.at(main_processor.node_time).strftime("CLOCKSYNC: TIME = %H:%M:%S DELTA = #{delta}") if user_initiated
				else
					$log.debug "Node's (#{main_processor.source_hostname}) time is ahead of node (#{control_message_packet.source_name}) and should NOT be synced."
				end

				return nil, {}  # return nil because packet has made a round trip
			else
				# hasn't gotten back to source yet, so return packet so that it'll be forwarded
				return control_message_packet, {}
			end
		else
			# arrived at the destination, send back to source node so that the source can 
			# sync its node time if need be
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				$log.debug "CLOCKSYNC got to the destination (#{main_processor.source_hostname} successfully.)"
				$stderr.puts Time.at(main_processor.node_time).strftime("CLOCKSYNC FROM #{control_message_packet.source_name}: TIME = %H:%M:%S") if user_initiated

				payload["destination_time"] = main_processor.node_time
				control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "CLOCKSYNC", payload, control_message_packet.time_sent)
			end

			control_message_packet.payload = payload
			return control_message_packet, {}
		end
	end

	# ----------------------------------------------------------
	# Helper method used to determine if a packet has timed
	# out or not. Does this by comparing the node's time
	# with the packet's origin time.
	# ----------------------------------------------------------
	def has_timed_out(main_processor, packet_time)
		return main_processor.node_time - packet_time > main_processor.ping_timeout 
	end

end
