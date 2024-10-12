#!/usr/bin/env python3
import sys
from TOSSIM import *
from CommandMsg import *

class TestSim:
    moteids = []
    # COMMAND TYPES
    CMD_PING = 0
    CMD_NEIGHBOR_DUMP = 1
    CMD_ROUTE_DUMP = 3

    # CHANNELS - see includes/channels.h
    COMMAND_CHANNEL = "command"
    GENERAL_CHANNEL = "general"

    # Project 1
    NEIGHBOR_CHANNEL = "neighbor"
    FLOODING_CHANNEL = "flooding"

    # Project 2
    ROUTING_CHANNEL = "routing"

    # Project 3
    TRANSPORT_CHANNEL = "transport"

    # Personal Debugging Channels for some of the additional models implemented.
    HASHMAP_CHANNEL = "hashmap"

    # Initialize Vars
    numMote = 0

    def __init__(self):
        self.t = Tossim([])
        self.r = self.t.radio()

    # Load a topo file and use it.
    def loadTopo(self, topoFile):
        print('Creating Topology!')
        # Read topology file.
        topoFilePath = 'topo/' + topoFile
        try:
            with open(topoFilePath, "r") as f:
                self.numMote = int(f.readline())
                print('Number of Motes:', self.numMote)
                for line in f:
                    s = line.strip().split()
                    if s:
                        print(" ", s[0], " ", s[1], " ", s[2])
                        self.r.add(int(s[0]), int(s[1]), float(s[2]))
                        if int(s[0]) not in self.moteids:
                            self.moteids.append(int(s[0]))
                        if int(s[1]) not in self.moteids:
                            self.moteids.append(int(s[1]))
        except FileNotFoundError:
            print(f"Topology file {topoFilePath} not found.")
            sys.exit(1)

    # Load a noise file and apply it.
    def loadNoise(self, noiseFile):
        if self.numMote == 0:
            print("Create a topology first.")
            return

        # Get and Create a Noise Model
        noiseFilePath = 'noise/' + noiseFile
        try:
            with open(noiseFilePath, "r") as noise:
                for line in noise:
                    str1 = line.strip()
                    if str1:
                        val = int(str1)
                        for i in self.moteids:
                            self.t.getNode(i).addNoiseTraceReading(val)
            for i in self.moteids:
                print("Creating noise model for", i)
                self.t.getNode(i).createNoiseModel()
        except FileNotFoundError:
            print(f"Noise file {noiseFilePath} not found.")
            sys.exit(1)

    def bootNode(self, nodeID):
        if self.numMote == 0:
            print("Create a topology first.")
            return
        self.t.getNode(nodeID).bootAtTime(1333 * nodeID)

    def bootAll(self):
        for i in self.moteids:
            self.bootNode(i)

    def moteOff(self, nodeID):
        self.t.getNode(nodeID).turnOff()

    def moteOn(self, nodeID):
        self.t.getNode(nodeID).turnOn()

    def run(self, ticks):
        for _ in range(ticks):
            self.t.runNextEvent()

    # Run simulation for a specified amount of time.
    def runTime(self, amount):
        self.run(int(amount * self.t.ticksPerSecond() / 1000))

    # Generic Command
    def sendCMD(self, ID, dest, payloadStr):
        msg = CommandMsg()
        msg.set_dest(dest)
        msg.set_id(ID)
        msg.setString_payload(payloadStr)

        pkt = self.t.newPacket()
        pkt.setType(msg.get_amType())
        pkt.setDestination(dest)
        pkt.setData(msg.data)
        pkt.deliver(dest, self.t.time() + 5)

    def ping(self, source, dest, msg):
        self.sendCMD(self.CMD_PING, source, "{}{}".format(chr(dest), msg))

    def neighborDMP(self, destination):
        self.sendCMD(self.CMD_NEIGHBOR_DUMP, destination, "neighbor command")

    def routeDMP(self, destination):
        self.sendCMD(self.CMD_ROUTE_DUMP, destination, "routing command")

    def addChannel(self, channelName, out=sys.stdout):
        print('Adding Channel', channelName)
        self.t.addChannel(channelName, out)

def main():
    s = TestSim()
    s.runTime(1)
    s.loadTopo("example.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)

    # Run the simulation for a short time to initialize
    s.runTime(1)

    # Send ping from node 1 to node 2
    s.ping(1, 2, "Hello, World")
    s.runTime(1)

    # Send ping from node 1 to node 3
    s.ping(1, 3, "Hi!")
    s.runTime(1)

    # Continue the simulation
    s.runTime(10)

if __name__ == '__main__':
    main()
