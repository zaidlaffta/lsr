#include "../../includes/channels.h"
#include "../../includes/protocol.h"
#include "../../includes/packet.h"

enum {
    ROUTING_TABLE_REBUILD_DELAY = 5000,
    MAX_LINKS_IN_NETWORK = 1024,
};

typedef struct {
    uint8_t nextHop;
    uint8_t cost;
} destination_node;

typedef struct {
    uint16_t src;
    uint16_t dest;
    uint8_t cost;
    uint8_t padding;
} link;

module RoutingTableP {
    uses interface Timer<TMilli> as rebuildRoutingTableTimer;
    uses interface Hashmap<destination_node> as routingTable;
    uses interface Hashmap<destination_node> as unvisitedNodes;
    uses interface SimpleSend as Sender;
    uses interface NeighborDiscovery;

    provides interface RoutingTable;
}

implementation {
    uint16_t routingTableFloodSeq = 0;
    link network_links[MAX_LINKS_IN_NETWORK];
    uint16_t receivedLinks = 0;

    command void RoutingTable.start() {
        call routingTable.reset();
        receivedLinks = 0;
        call NeighborDiscovery.start();
        call rebuildRoutingTableTimer.startPeriodic(ROUTING_TABLE_REBUILD_DELAY);
    }

    command uint16_t RoutingTable.getNextHop(uint16_t dest) {
        if (call routingTable.contains(dest)) {
            return (call routingTable.get(dest)).nextHop;
        } else {
            return ~0;
        }
    }

    event void rebuildRoutingTableTimer.fired() {
        LinkState lsa = call NeighborDiscovery.getOwnLinkstate();
        uint8_t i;
        error_t error;
        uint16_t fail_safe = 1000;
        uint16_t neighborCount = call NeighborDiscovery.getNeighborCount();
        uint16_t *neighborIDs = call NeighborDiscovery.getNeighborIDs();
        uint16_t currentNodeId;
        destination_node currentNode;

        // Prepare the packet for the LSA flood
        pack packet;
        packet.src = TOS_NODE_ID;
        packet.dest = AM_BROADCAST_ADDR;
        packet.TTL = MAX_TTL;
        packet.seq = routingTableFloodSeq++;
        packet.protocol = PROTOCOL_LINKSTATE;

        memcpy(packet.payload, &lsa, sizeof(lsa));

        // Send LSA flood
        for (i = 0; i < neighborCount; i++) {
            error = call Sender.send(packet, neighborIDs[i]);
            if (error != SUCCESS) {
                dbg(GENERAL_CHANNEL, "Failed to flood LSA to node %u\n", neighborIDs[i]);
            }
        }

        if (routingTableFloodSeq % 4 != 0) {
            return; // Only rebuild the routing table every 4th flood
        }

        call routingTable.reset();
        call unvisitedNodes.reset();

        // Detect nodes in the network based on received links
        for (i = 0; i < receivedLinks; i++) {
            destination_node unvisited;
            unvisited.cost = ~0;
            call unvisitedNodes.insert(network_links[i].dest, unvisited);
            call unvisitedNodes.insert(network_links[i].src, unvisited);
        }

        // Assign known costs of immediate neighbors
        currentNode.cost = ~0;
        for (i = 0; i < lsa.count; i++) {
            destination_node node;
            node.nextHop = lsa.neighborIDs[i];
            node.cost = 1; // Treat all links as equally expensive for now
            call unvisitedNodes.insert(lsa.neighborIDs[i], node);

            // Select the closest neighbor
            if (currentNode.cost > node.cost) {
                currentNode = node;
                currentNodeId = lsa.neighborIDs[i];
            }
        }

        // Remove the current node from unvisited list
        call unvisitedNodes.remove(TOS_NODE_ID);

        // Dijkstra's algorithm for shortest path
        while (call unvisitedNodes.size() > 0 && fail_safe-- > 0) {
            uint16_t unvisitedNodeCount;
            uint16_t *unvisitedNodeIDs;
            uint8_t leastCost = ~0;

            for (i = 0; i < receivedLinks && fail_safe-- > 0; i++) {
                uint16_t neighborID;

                if (network_links[i].src == currentNodeId) {
                    neighborID = network_links[i].dest;
                } else if (network_links[i].dest == currentNodeId) {
                    neighborID = network_links[i].src;
                } else {
                    continue; // Edge doesn't touch the current node
                }

                if (call unvisitedNodes.contains(neighborID)) {
                    uint8_t cost_through_current_node = currentNode.cost + network_links[i].cost;
                    if ((call unvisitedNodes.get(neighborID)).cost > cost_through_current_node) {
                        destination_node updated_node;
                        updated_node.cost = cost_through_current_node;
                        updated_node.nextHop = currentNode.nextHop;
                        call unvisitedNodes.insert(neighborID, updated_node);
                    }
                }
            }

            // Move tentative node to confirmed
            call unvisitedNodes.remove(currentNodeId);
            call routingTable.insert(currentNodeId, currentNode);

            // Find next unvisited node with the smallest tentative distance
            unvisitedNodeCount = call unvisitedNodes.size();
            unvisitedNodeIDs = call unvisitedNodes.getKeys();
            for (i = 0; i < unvisitedNodeCount && fail_safe-- > 0; i++) {
                uint16_t nodeID = unvisitedNodeIDs[i];
                destination_node next_node = call unvisitedNodes.get(nodeID);
                if (next_node.cost < leastCost) {
                    currentNode = next_node;
                    currentNodeId = nodeID;
                }
            }
        }

        if (fail_safe == 0) {
            dbg(GENERAL_CHANNEL, "Unvisited nodes remaining: %u\n", call unvisitedNodes.size());
        }

        receivedLinks = 0;
    }

    command message_t *RoutingTable.receive(message_t * raw_msg, void *payload, uint8_t len) {
        pack *packet = (pack *)payload;
        LinkState *lsa = (LinkState*)packet->payload;

        for (uint16_t i = 0; i < lsa->count; i++) {
            uint16_t lowID = lsa->neighborIDs[i];
            uint16_t highID = packet->src;

            if (lowID > highID) {
                uint16_t temp = lowID;
                lowID = highID;
                highID = temp;
            }

            bool isDuplicate = FALSE;
            for (uint16_t j = 0; j < receivedLinks; j++) {
                if (network_links[j].src == lowID && network_links[j].dest == highID) {
                    isDuplicate = TRUE;
                    break;
                }
            }

            if (!isDuplicate) {
                network_links[receivedLinks].src = lowID;
                network_links[receivedLinks].dest = highID;
                network_links[receivedLinks].cost = 1;
                receivedLinks++;
            }
        }

        return raw_msg;
    }

    command void RoutingTable.print() {
        uint16_t nodeCount = call routingTable.size();
        uint16_t *nodeIDs = call routingTable.getKeys();

        dbg(ROUTING_CHANNEL, "Node %u Routing Table\n", TOS_NODE_ID);
        dbg(ROUTING_CHANNEL, "Dest | Next | Cost\n");
        dbg(ROUTING_CHANNEL, "-----+------+-----\n");

        for (uint16_t i = 0; i <= nodeCount + 1; i++) {
            for (uint16_t j = 0; j < nodeCount; j++) {
                uint16_t dest = nodeIDs[j];
                destination_node node = call routingTable.get(dest);
                if (dest == i) {
                    dbg(ROUTING_CHANNEL, "%4u | %4u | %4u\n", dest, node.nextHop, node.cost);
                }
            }
        }
    }
}
