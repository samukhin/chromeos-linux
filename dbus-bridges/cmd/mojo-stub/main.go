// mojo-stub: ipcz broker for Chrome Ash (r1700040+).
//
// Chrome (a non-broker node, because --disable-mojo-broker) dials
// /run/mojo/service_manager.sock and completes a ConnectFromNonBrokerToBroker
// handshake with us. We are its ipcz broker. When Chrome spawns a child (GPU,
// utility) it cannot connect to it directly (both are non-brokers), so it sends
// us a ReferNonBroker message carrying a transport to the child. We then relay
// the referral: read the child's ConnectToReferredBroker greeting, create a
// socketpair, and hand each side the details (transport + shared link memory)
// so browser and child establish a direct ipcz NodeLink between themselves.
//
// Wire format (mojo/core/channel.h + ipcz message.h):
//
//	ChannelLinux frame = IpczHeader (16 bytes) + ipcz message data:
//	  [0:2]   size (uint16) — 16
//	  [2:4]   num_handles (uint16) — fds attached out-of-band via SCM_RIGHTS
//	  [4:8]   num_bytes (uint32) — total frame size incl. this header
//	  [8:16]  creation_timeticks_us (int64)
//
//	ipcz MessageHeader (24 bytes):
//	  [0]     size (uint8) — 24
//	  [1]     version (uint8) — 0
//	  [2]     message_id (uint8)
//	  [8:16]  node_sequence_number (uint64)
//	  [16:20] driver_object_data_array (uint32) — offset of DriverObjectData[]
//
//	Driver object (mojo/core/ipcz_driver/transport.cc):
//	  kTransport (type 0): ObjectHeader{size=8,type=0} + TransportHeader{8} +
//	            1 fd (out-of-band)
//	  kSharedBuffer (type 1): ObjectHeader{size=8,type=1} + BufferHeader{32} +
//	            2 fds (rw + ro reopen) (out-of-band)
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const socketPath = "/run/mojo/service_manager.sock"

const (
	primaryBufferSize = 128 * 1024
	ipczHeaderSize    = 16
	msgHeaderSize     = 24

	msgConnectBrokerToNonBroker   = 0
	msgConnectNonBrokerToBroker   = 1
	msgReferNonBroker             = 2
	msgConnectToReferredBroker    = 3
	msgConnectToReferredNonBroker = 4
	msgNonBrokerReferralAccepted  = 5

	msgRequestIntroduction = 10
	msgAcceptIntroduction  = 11
	msgRejectIntroduction  = 12

	msgAcceptParcel          = 20
	msgAcceptParcelDriverObj = 21

	objTypeTransport      = 0
	objTypeSharedBuffer   = 1
	endpointTypeNonBroker = 1

	bufferModeWritable = 1
)

// peer is one node connected to us (the broker) over a link: either the
// browser (over the accepted unix connection) or a referred child (over its
// platform-channel transport fd). All writes to a peer's link are serialized.
type peer struct {
	mu    sync.Mutex
	name  [16]byte
	proto uint32
	fd    int // raw socket fd; -1 when conn is used
	conn  *net.UnixConn
}

// send transmits one ipcz channel frame carrying `rights` fds via SCM_RIGHTS.
func (p *peer) send(frame []byte, rights ...int) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	var oob []byte
	if len(rights) > 0 {
		oob = syscall.UnixRights(rights...)
	}
	if p.conn != nil {
		_, _, err := p.conn.WriteMsgUnix(frame, oob, nil)
		return err
	}
	if p.fd < 0 {
		return fmt.Errorf("peer %x: no transport", p.name[:8])
	}
	return writeFD(p.fd, frame, oob)
}

var (
	peersMu   sync.Mutex
	peers     = map[[16]byte]*peer{}
	introMu   sync.Mutex
	introBusy = map[string]bool{}
	introDone = map[string]bool{}
)

func registerPeer(p *peer) {
	peersMu.Lock()
	defer peersMu.Unlock()
	peers[p.name] = p
}

// unregisterPeer removes the mapping only if it still points at p (a
// replacement peer may already have taken the same name).
func unregisterPeer(p *peer) {
	peersMu.Lock()
	defer peersMu.Unlock()
	if peers[p.name] == p {
		delete(peers, p.name)
	}
}

func lookupPeer(name [16]byte) *peer {
	peersMu.Lock()
	defer peersMu.Unlock()
	return peers[name]
}

func introKey(a, b [16]byte) string {
	if string(a[:]) < string(b[:]) {
		return string(a[:]) + string(b[:])
	}
	return string(b[:]) + string(a[:])
}

// introBegin marks an introduction as in progress. Returns false if it is
// already in progress or has been completed before.
func introBegin(k string) bool {
	introMu.Lock()
	defer introMu.Unlock()
	if introBusy[k] || introDone[k] {
		return false
	}
	introBusy[k] = true
	return true
}

func introFinish(k string, ok bool) {
	introMu.Lock()
	defer introMu.Unlock()
	delete(introBusy, k)
	if ok {
		introDone[k] = true
	}
}

func main() {
	log.SetPrefix("[mojo-stub] ")
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	os.MkdirAll("/run/mojo", 0755)
	os.Remove(socketPath)

	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		log.Fatalf("listen %s: %v", socketPath, err)
	}
	defer ln.Close()
	os.Chmod(socketPath, 0666)
	log.Printf("listening on %s", socketPath)

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go handleChrome(conn.(*net.UnixConn))
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
}

func handleChrome(conn *net.UnixConn) {
	defer conn.Close()
	log.Printf("Chrome connected")

	payload, fds, err := readIpczFrame(conn)
	if err != nil {
		log.Printf("read handshake: %v", err)
		closeFds(fds)
		return
	}

	msgID := -1
	proto := uint32(0)
	portals := uint32(8)
	if len(payload) >= 40 {
		msgID = int(payload[2])
		proto = binary.LittleEndian.Uint32(payload[32:36])
		portals = binary.LittleEndian.Uint32(payload[36:40])
	}
	log.Printf("recv handshake id=%d protocol_version=%d num_initial_portals=%d len=%d",
		msgID, proto, portals, len(payload))
	closeFds(fds)
	if msgID != msgConnectNonBrokerToBroker {
		log.Printf("WARNING: expected id=%d, sending reply anyway", msgConnectNonBrokerToBroker)
	}

	// Names we assign: our broker name, and the browser's node name. These must
	// stay consistent across the handshake and every referral we relay.
	brokerName := randName()
	browserName := randName()
	log.Printf("names: broker=%x browser=%x proto=%d portals=%d",
		brokerName, browserName, proto, portals)

	if err := sendInitialHandshake(conn, brokerName, browserName, portals, proto); err != nil {
		log.Printf("send handshake: %v", err)
		return
	}

	// The browser is a peer like any child: children may ask to be introduced
	// to it, and it may refer new children.
	browserPeer := &peer{name: browserName, proto: proto, fd: -1, conn: conn}
	registerPeer(browserPeer)
	defer unregisterPeer(browserPeer)

	// Message loop: handle ReferNonBroker referrals; drain everything else.
	drainAndRelay(conn, brokerName, browserName, browserPeer)
	log.Printf("Chrome disconnected")
}

func sendInitialHandshake(conn *net.UnixConn, brokerName, browserName [16]byte, portals, proto uint32) error {
	rw, ro, err := makeSharedBuffer()
	if err != nil {
		return err
	}
	defer syscall.Close(rw)
	defer syscall.Close(ro)

	msg := make([]byte, ipczHeaderSize+168)
	data := msg[ipczHeaderSize:]

	// IpczHeader
	binary.LittleEndian.PutUint16(msg[0:], ipczHeaderSize)
	binary.LittleEndian.PutUint16(msg[2:], 2) // num_handles: rw + ro
	binary.LittleEndian.PutUint32(msg[4:], uint32(len(msg)))
	binary.LittleEndian.PutUint64(msg[8:], uint64(time.Now().UnixMicro()))

	// MessageHeader
	data[0] = msgHeaderSize
	data[1] = 0
	data[2] = msgConnectBrokerToNonBroker
	binary.LittleEndian.PutUint32(data[16:], 104) // driver_object_data_array

	// Params (StructHeader.size=64)
	binary.LittleEndian.PutUint32(data[24:], 64)
	copy(data[32:48], brokerName[:])
	copy(data[48:64], browserName[:])
	binary.LittleEndian.PutUint32(data[64:], proto)
	binary.LittleEndian.PutUint32(data[68:], portals)
	binary.LittleEndian.PutUint32(data[72:], 0)  // buffer obj index
	binary.LittleEndian.PutUint32(data[80:], 88) // features array offset

	// Features array @88
	binary.LittleEndian.PutUint32(data[88:], 16)
	binary.LittleEndian.PutUint32(data[92:], 1)

	// DriverObjectData array @104
	binary.LittleEndian.PutUint32(data[104:], 16)
	binary.LittleEndian.PutUint32(data[108:], 1)
	binary.LittleEndian.PutUint32(data[112:], 120) // driver_data_array
	binary.LittleEndian.PutUint16(data[116:], 0)   // first_handle
	binary.LittleEndian.PutUint16(data[118:], 2)   // num_handles

	// Object 0 data @120: ObjectHeader{kSharedBuffer} + BufferHeader
	binary.LittleEndian.PutUint32(data[120:], 48)
	binary.LittleEndian.PutUint32(data[124:], 40)
	binary.LittleEndian.PutUint32(data[128:], 8)
	binary.LittleEndian.PutUint32(data[132:], objTypeSharedBuffer)
	binary.LittleEndian.PutUint32(data[136:], 32)
	binary.LittleEndian.PutUint32(data[140:], primaryBufferSize)
	binary.LittleEndian.PutUint32(data[144:], bufferModeWritable)
	binary.LittleEndian.PutUint64(data[152:], rand.Uint64())
	binary.LittleEndian.PutUint64(data[160:], rand.Uint64())

	oob := syscall.UnixRights(rw, ro)
	if _, _, err := conn.WriteMsgUnix(msg, oob, nil); err != nil {
		return err
	}
	log.Printf("sent ConnectFromBrokerToNonBroker (broker=%x browser=%x)", brokerName[:8], browserName[:8])
	return nil
}

// drainAndRelay reads frames from the browser link. ReferNonBroker (id=2)
// referrals are relayed; everything else is drained (closing stray fds).
func drainAndRelay(conn *net.UnixConn, brokerName, browserName [16]byte, browserPeer *peer) {
	buf := make([]byte, 0, 8192)
	oob := make([]byte, 2048)
	scratch := make([]byte, 8192)
	seen := map[byte]int{}
	var mu sync.Mutex

	for {
		n, oobn, _, _, err := conn.ReadMsgUnix(scratch, oob)
		var fds []int
		if oobn > 0 {
			fds = parseFds(oob[:oobn])
		}
		if n > 0 {
			buf = append(buf, scratch[:n]...)
		}
		for len(buf) >= ipczHeaderSize {
			frameSize := int(binary.LittleEndian.Uint32(buf[4:8]))
			if frameSize < ipczHeaderSize || frameSize > 16*1024*1024 {
				log.Printf("bogus frame size %d, dropping", frameSize)
				buf = nil
				break
			}
			if len(buf) < frameSize {
				break
			}
			frame := make([]byte, frameSize)
			copy(frame, buf[:frameSize])
			buf = buf[frameSize:]

			if len(frame) < ipczHeaderSize+3 {
				continue
			}
			data := frame[ipczHeaderSize:]
			msgID := data[2]
			mu.Lock()
			seen[msgID]++
			mu.Unlock()

			switch msgID {
			case msgReferNonBroker:
				// fds that arrived with THIS frame belong to it. Any fds that
				// arrived in the same read but for other frames are mishandled;
				// in practice Chrome sends one referral per frame with its fd.
				go handleReferral(data, fds, browserPeer, brokerName, browserName)
				fds = nil
			case msgRequestIntroduction:
				handleRequestIntroduction(browserPeer, data, brokerName)
			default:
				if msgID != msgAcceptParcel && msgID != msgAcceptParcelDriverObj &&
					(msgID < 30 || msgID > 36) {
					log.Printf("recv msg id=%d len=%d (draining)", msgID, len(data))
				}
			}
		}
		closeFds(fds)
		if err != nil {
			log.Printf("browser link closed: %v (msgtypes %v)", err, seen)
			return
		}
	}
}

// handleReferral relays one ReferNonBroker: it greets the child, builds a
// socketpair, and tells both child and referrer how to connect to each other.
// The referrer is the browser (its unix conn) or a child (its broker link fd).
func handleReferral(refData []byte, refFds []int, referrer *peer, brokerName, browserName [16]byte) {
	// ReferNonBroker params: StructHeader@24, V0@32 {referral_id u64,
	// num_initial_portals u32, transport u32 (driver object index)}.
	// The caller only guarantees the header + msgID bytes; a short frame must
	// not panic (the listen socket is world-accessible).
	if len(refData) < 48 {
		log.Printf("referral: short frame (%d bytes), dropping", len(refData))
		closeFds(refFds)
		return
	}
	referralID := binary.LittleEndian.Uint64(refData[32:40])
	numPortals := binary.LittleEndian.Uint32(refData[40:44])
	transportIdx := binary.LittleEndian.Uint32(refData[44:48])

	// Map the transport driver object index to the actual fd.
	transportFD := driverObjectFD(refData, refFds, transportIdx)
	if transportFD < 0 {
		log.Printf("referral %d: no transport fd (idx=%d, got %d fds)", referralID, transportIdx, len(refFds))
		closeFds(refFds)
		return
	}
	// Close any fds we didn't consume.
	for _, fd := range refFds {
		if fd != transportFD {
			syscall.Close(fd)
		}
	}

	// Read the child's ConnectToReferredBroker greeting over the transport. The
	// fd is non-blocking and the greeting arrives asynchronously, so poll for
	// readiness first, then read in blocking mode.
	if !waitReadable(transportFD, 10000) {
		log.Printf("referral %d: no greeting from child (timeout)", referralID)
		syscall.Close(transportFD)
		return
	}
	unix.SetNonblock(transportFD, false)
	greet, err := readIpczFD(transportFD)
	if err != nil {
		log.Printf("referral %d: read greeting: %v", referralID, err)
		syscall.Close(transportFD)
		return
	}
	childProto := uint32(0)
	childPortals := numPortals
	if len(greet) >= 44 {
		if int(greet[2]) != msgConnectToReferredBroker {
			log.Printf("referral %d: expected ConnectToReferredBroker, got id=%d", referralID, greet[2])
		}
		childProto = binary.LittleEndian.Uint32(greet[32:36])
		childPortals = binary.LittleEndian.Uint32(greet[36:40])
	}
	// The child's endpoint type, read from the TransportHeader of the referral
	// transport the browser sent us. browserEnd (sent back to the browser) must
	// advertise this type; childEnd (sent to the child) advertises the browser's
	// type (kNonBroker, since Chrome runs with --disable-mojo-broker).
	childType := readTransportDestType(refData, transportIdx)
	log.Printf("referral %d: child greeted (proto=%d portals=%d childType=%d)", referralID, childProto, childPortals, childType)

	// Allocate the two link-memory buffers the broker normally provides.
	linkRW, linkRO, err := makeLinkBuffer()
	if err != nil {
		log.Printf("referral %d: link buffer: %v", referralID, err)
		syscall.Close(transportFD)
		return
	}
	defer syscall.Close(linkRW)
	defer syscall.Close(linkRO)
	clientRW, clientRO, err := makeLinkBuffer()
	if err != nil {
		log.Printf("referral %d: client buffer: %v", referralID, err)
		syscall.Close(transportFD)
		return
	}
	defer syscall.Close(clientRW)
	defer syscall.Close(clientRO)

	// Direct transport pair between browser and child.
	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		log.Printf("referral %d: socketpair: %v", referralID, err)
		syscall.Close(transportFD)
		return
	}
	browserEnd, childEnd := pair[0], pair[1]
	defer syscall.Close(browserEnd)
	defer syscall.Close(childEnd)

	gpuName := randName()

	// Register the new child as a peer before greeting it: it may ask for an
	// introduction to another node as soon as its link to us is up.
	childPeer := &peer{name: gpuName, proto: childProto, fd: transportFD}
	registerPeer(childPeer)

	// 1) Tell the child how to reach both us (broker) and its referrer.
	c2n := buildConnectToReferredNonBroker(gpuName, brokerName, referrer.name,
		childProto, childProto, numPortals,
		linkRW, linkRO, childEnd, clientRW, clientRO)
	oobChild := syscall.UnixRights(linkRW, linkRO, childEnd, clientRW, clientRO)
	if err := writeFD(transportFD, c2n, oobChild); err != nil {
		log.Printf("referral %d: send ConnectToReferredNonBroker: %v", referralID, err)
		unregisterPeer(childPeer)
		return
	}
	log.Printf("referral %d: sent ConnectToReferredNonBroker to child", referralID)

	// 2) Tell the referrer the referral succeeded and how to reach the child.
	n2b := buildNonBrokerReferralAccepted(referralID, childProto, childPortals,
		gpuName, browserEnd, clientRW, clientRO, childType)
	if err := referrer.send(n2b, browserEnd, clientRW, clientRO); err != nil {
		log.Printf("referral %d: send NonBrokerReferralAccepted to %x: %v",
			referralID, referrer.name[:8], err)
		unregisterPeer(childPeer)
		return
	}
	log.Printf("referral %d: relay complete (child=%x referrer=%x)",
		referralID, gpuName, referrer.name[:8])

	// Keep the child's broker link alive by reading its frames in the
	// background so its socket buffer never fills and the link stays open.
	go drainFD(transportFD, childPeer, brokerName, browserName)
}

// buildConnectToReferredNonBroker assembles the id=4 message with 3 driver
// objects: [sharedBuffer(link), transport(childEnd), sharedBuffer(client)].
func buildConnectToReferredNonBroker(name, brokerName, referrerName [16]byte,
	brokerProto, referrerProto, numPortals uint32,
	linkRW, linkRO, childEnd, clientRW, clientRO int) []byte {
	// Layout: MessageHeader(24) + params(88: V0=80 + V1=8) + features(16) +
	// 3 object arrays + driver_object_data array. All offsets 8-aligned.
	//
	// params V0: name(16) broker_name(16) referrer_name(16) +
	//   broker_proto(4) referrer_proto(4) num_portals(4) +
	//   broker_link_buffer(4) referrer_link_transport(4) referrer_link_buffer(4)
	// params V1: broker_features(4) referrer_features(4)
	const paramsSize = 88
	objSizes := []int{40, 16, 40} // buffer, transport, buffer

	off := msgHeaderSize
	paramsOff := off
	off += paramsSize

	off = align8(off)
	featOff := off
	off += 16 // ArrayHeader{16,1} + u64=0

	objOff := make([]int, 3)
	for i, sz := range objSizes {
		off = align8(off)
		objOff[i] = off
		off += 8 + sz
	}

	off = align8(off)
	dodOff := off
	off += 8 + 3*8

	msg := make([]byte, ipczHeaderSize+off)
	data := msg[ipczHeaderSize:]

	binary.LittleEndian.PutUint16(msg[0:], ipczHeaderSize)
	binary.LittleEndian.PutUint16(msg[2:], 5) // link rw/ro, transport, client rw/ro
	binary.LittleEndian.PutUint32(msg[4:], uint32(len(msg)))
	binary.LittleEndian.PutUint64(msg[8:], uint64(time.Now().UnixMicro()))

	data[0] = msgHeaderSize
	data[1] = 0
	data[2] = msgConnectToReferredNonBroker
	binary.LittleEndian.PutUint32(data[16:], uint32(dodOff))

	p := paramsOff
	binary.LittleEndian.PutUint32(data[p:], paramsSize)
	copy(data[p+8:p+24], name[:])
	copy(data[p+24:p+40], brokerName[:])
	copy(data[p+40:p+56], referrerName[:])
	binary.LittleEndian.PutUint32(data[p+56:], brokerProto)
	binary.LittleEndian.PutUint32(data[p+60:], referrerProto)
	binary.LittleEndian.PutUint32(data[p+64:], numPortals)
	binary.LittleEndian.PutUint32(data[p+68:], 0) // broker_link_buffer obj idx
	binary.LittleEndian.PutUint32(data[p+72:], 1) // referrer_link_transport obj idx
	binary.LittleEndian.PutUint32(data[p+76:], 2) // referrer_link_buffer obj idx
	// V1 features
	binary.LittleEndian.PutUint32(data[p+80:], uint32(featOff)) // broker_features
	binary.LittleEndian.PutUint32(data[p+84:], uint32(featOff)) // referrer_features

	writeFeaturesArray(data, featOff)
	writeSharedBufferObj(data, objOff[0], 40, linkRW)
	writeTransportObj(data, objOff[1], 16, endpointTypeNonBroker) // child sees browser (non-broker)
	writeSharedBufferObj(data, objOff[2], 40, clientRW)

	binary.LittleEndian.PutUint32(data[dodOff:], 8+3*8)
	binary.LittleEndian.PutUint32(data[dodOff+4:], 3)
	binary.LittleEndian.PutUint32(data[dodOff+8:], uint32(objOff[0]))
	binary.LittleEndian.PutUint16(data[dodOff+12:], 0)
	binary.LittleEndian.PutUint16(data[dodOff+14:], 2)
	binary.LittleEndian.PutUint32(data[dodOff+16:], uint32(objOff[1]))
	binary.LittleEndian.PutUint16(data[dodOff+20:], 2)
	binary.LittleEndian.PutUint16(data[dodOff+22:], 1)
	binary.LittleEndian.PutUint32(data[dodOff+24:], uint32(objOff[2]))
	binary.LittleEndian.PutUint16(data[dodOff+28:], 3)
	binary.LittleEndian.PutUint16(data[dodOff+30:], 2)

	_ = linkRO
	_ = clientRO
	return msg
}

// buildNonBrokerReferralAccepted assembles the id=5 message with 2 driver
// objects: [transport(browserEnd), sharedBuffer(client)].
func buildNonBrokerReferralAccepted(referralID uint64, proto, numPortals uint32,
	name [16]byte, browserEnd, clientRW, clientRO int, childType uint32) []byte {
	// Layout: MessageHeader(24) + params(56: V0=48 + V1=8) + features(16) +
	// 2 object arrays + driver_object_data array.
	const paramsSize = 56
	objSizes := []int{16, 40} // transport, shared buffer

	off := msgHeaderSize
	paramsOff := off
	off += paramsSize

	off = align8(off)
	featOff := off
	off += 16

	objOff := make([]int, 2)
	for i, sz := range objSizes {
		off = align8(off)
		objOff[i] = off
		off += 8 + sz
	}
	off = align8(off)
	dodOff := off
	off += 8 + 2*8

	msg := make([]byte, ipczHeaderSize+off)
	data := msg[ipczHeaderSize:]

	binary.LittleEndian.PutUint16(msg[0:], ipczHeaderSize)
	binary.LittleEndian.PutUint16(msg[2:], 3) // transport + client rw/ro
	binary.LittleEndian.PutUint32(msg[4:], uint32(len(msg)))
	binary.LittleEndian.PutUint64(msg[8:], uint64(time.Now().UnixMicro()))

	data[0] = msgHeaderSize
	data[1] = 0
	data[2] = msgNonBrokerReferralAccepted
	binary.LittleEndian.PutUint32(data[16:], uint32(dodOff))

	p := paramsOff
	binary.LittleEndian.PutUint32(data[p:], paramsSize)
	binary.LittleEndian.PutUint64(data[p+8:], referralID)
	binary.LittleEndian.PutUint32(data[p+16:], proto)
	binary.LittleEndian.PutUint32(data[p+20:], numPortals)
	copy(data[p+24:p+40], name[:])
	binary.LittleEndian.PutUint32(data[p+40:], 0)               // transport obj idx
	binary.LittleEndian.PutUint32(data[p+44:], 1)               // buffer obj idx
	binary.LittleEndian.PutUint32(data[p+48:], uint32(featOff)) // V1 features

	writeFeaturesArray(data, featOff)
	writeTransportObj(data, objOff[0], 16, childType)
	writeSharedBufferObj(data, objOff[1], 40, clientRW)

	binary.LittleEndian.PutUint32(data[dodOff:], 8+2*8)
	binary.LittleEndian.PutUint32(data[dodOff+4:], 2)
	binary.LittleEndian.PutUint32(data[dodOff+8:], uint32(objOff[0]))
	binary.LittleEndian.PutUint16(data[dodOff+12:], 0)
	binary.LittleEndian.PutUint16(data[dodOff+14:], 1)
	binary.LittleEndian.PutUint32(data[dodOff+16:], uint32(objOff[1]))
	binary.LittleEndian.PutUint16(data[dodOff+20:], 1)
	binary.LittleEndian.PutUint16(data[dodOff+22:], 2)

	_ = clientRO
	return msg
}

// writeFeaturesArray writes ArrayHeader{16,1} + u64 bitfield 0 (baseline
// features: memv2 off) at off.
func writeFeaturesArray(data []byte, off int) {
	binary.LittleEndian.PutUint32(data[off:], 16)
	binary.LittleEndian.PutUint32(data[off+4:], 1)
	// u64 bitfield = 0 (zero value)
}

// writeSharedBufferObj writes ArrayHeader + ObjectHeader{kSharedBuffer} +
// BufferHeader at off. The ArrayHeader covers the object bytes (8+32=40).
func writeSharedBufferObj(data []byte, off, objSize int, rwfd int) {
	binary.LittleEndian.PutUint32(data[off:], uint32(8+objSize)) // num_bytes
	binary.LittleEndian.PutUint32(data[off+4:], uint32(objSize)) // num_elements
	binary.LittleEndian.PutUint32(data[off+8:], 8)               // ObjectHeader.size
	binary.LittleEndian.PutUint32(data[off+12:], objTypeSharedBuffer)
	binary.LittleEndian.PutUint32(data[off+16:], 32) // BufferHeader.size
	binary.LittleEndian.PutUint32(data[off+20:], primaryBufferSize)
	binary.LittleEndian.PutUint32(data[off+24:], bufferModeWritable)
	binary.LittleEndian.PutUint64(data[off+32:], rand.Uint64())
	binary.LittleEndian.PutUint64(data[off+40:], rand.Uint64())
	_ = rwfd
}

// writeTransportObj writes ArrayHeader + ObjectHeader{kTransport} +
// TransportHeader at off. TransportHeader: destination_type(u32) + 3 bools +
// reserved (8 bytes).
func writeTransportObj(data []byte, off, objSize int, destType uint32) {
	binary.LittleEndian.PutUint32(data[off:], uint32(8+objSize))
	binary.LittleEndian.PutUint32(data[off+4:], uint32(objSize))
	binary.LittleEndian.PutUint32(data[off+8:], 8) // ObjectHeader.size
	binary.LittleEndian.PutUint32(data[off+12:], objTypeTransport)
	// TransportHeader @ off+16
	binary.LittleEndian.PutUint32(data[off+16:], destType)
	// is_same_remote_process, is_peer_trusted, is_trusted_by_peer, reserved = 0
}

func align8(n int) int { return (n + 7) &^ 7 }

// readIpczFrame reads one complete channel frame from a net.UnixConn.
func readIpczFrame(conn *net.UnixConn) ([]byte, []int, error) {
	buf := make([]byte, 0, 4096)
	oob := make([]byte, 2048)
	var fds []int
	scratch := make([]byte, 4096)
	need := ipczHeaderSize
	for len(buf) < need {
		n, oobn, _, _, err := conn.ReadMsgUnix(scratch, oob)
		if n > 0 {
			buf = append(buf, scratch[:n]...)
		}
		if oobn > 0 {
			fds = append(fds, parseFds(oob[:oobn])...)
		}
		if err != nil {
			return buf, fds, err
		}
		if n == 0 {
			continue
		}
		if len(buf) >= ipczHeaderSize && need == ipczHeaderSize {
			total := int(binary.LittleEndian.Uint32(buf[4:8]))
			if total < ipczHeaderSize || total > 16*1024*1024 {
				return buf, fds, fmt.Errorf("bogus frame size %d", total)
			}
			need = total
		}
	}
	total := int(binary.LittleEndian.Uint32(buf[4:8]))
	return buf[ipczHeaderSize:total], fds, nil
}

// readIpczFD reads one complete channel frame from a raw socket fd (the child
// transport). No handles are expected on ConnectToReferredBroker.
func readIpczFD(fd int) ([]byte, error) {
	hdr := make([]byte, ipczHeaderSize)
	if err := readFull(fd, hdr); err != nil {
		return nil, err
	}
	total := int(binary.LittleEndian.Uint32(hdr[4:8]))
	if total < ipczHeaderSize || total > 16*1024*1024 {
		return nil, fmt.Errorf("bogus frame size %d", total)
	}
	rest := make([]byte, total-ipczHeaderSize)
	if err := readFull(fd, rest); err != nil {
		return nil, err
	}
	return rest, nil
}

func readFull(fd int, b []byte) error {
	for len(b) > 0 {
		n, err := unix.Read(fd, b)
		if err != nil {
			return err
		}
		if n == 0 {
			// EOF: raw read returns (0, nil) forever once the peer closed
			// the socket; without this the loop spins at 100% CPU.
			return io.EOF
		}
		b = b[n:]
	}
	return nil
}

// waitReadable polls fd until it is readable or the timeout (ms) elapses.
func waitReadable(fd int, ms int) bool {
	pfd := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	for {
		n, err := unix.Poll(pfd, ms)
		if err == unix.EINTR {
			continue
		}
		return err == nil && n > 0 && pfd[0].Revents&(unix.POLLIN|unix.POLLHUP) != 0
	}
}

// writeFD writes one channel frame (with optional SCM_RIGHTS fds) to a raw
// socket fd.
func writeFD(fd int, frame []byte, oob []byte) error {
	return unix.Sendmsg(fd, frame, oob, nil, 0)
}

// drainFD reads frames from a child's broker link. Introduction requests and
// referrals issued by the child are handled; everything else is drained so the
// socket buffer never fills and the link stays open.
func drainFD(fd int, self *peer, brokerName, browserName [16]byte) {
	var acc []byte
	var pending []int
	buf := make([]byte, 8192)
	oob := make([]byte, 4096)
	who := fmt.Sprintf("child[%x]", self.name[:8])

	defer func() {
		unregisterPeer(self)
		closeFds(pending)
		syscall.Close(fd)
		log.Printf("%s: link closed", who)
	}()

	for {
		n, oobn, _, _, err := unix.Recvmsg(fd, buf, oob, 0)
		if oobn > 0 {
			pending = append(pending, parseFds(oob[:oobn])...)
		}
		if n > 0 {
			acc = append(acc, buf[:n]...)
			for len(acc) >= ipczHeaderSize {
				frameSize := int(binary.LittleEndian.Uint32(acc[4:8]))
				if frameSize < ipczHeaderSize || frameSize > 16*1024*1024 {
					log.Printf("%s: bogus frame %d, dropping", who, frameSize)
					acc = nil
					break
				}
				if len(acc) < frameSize {
					break
				}
				data := acc[ipczHeaderSize:frameSize]
				// Fds carried by this read belong to the frame it completed.
				fds := pending
				pending = nil
				if len(data) < 3 {
					closeFds(fds)
					acc = acc[frameSize:]
					continue
				}
				id := data[2]
				switch id {
				case msgRequestIntroduction:
					closeFds(fds)
					handleRequestIntroduction(self, data, brokerName)
				case msgReferNonBroker:
					go handleReferral(data, fds, self, brokerName, browserName)
				default:
					closeFds(fds)
					if id != msgAcceptParcel && id != msgAcceptParcelDriverObj &&
						(id < 30 || id > 36) {
						log.Printf("%s: msg id=%d len=%d", who, id, len(data))
					}
				}
				acc = acc[frameSize:]
			}
		}
		if err != nil {
			log.Printf("%s: read error: %v", who, err)
			return
		}
		if n == 0 && oobn == 0 {
			// EOF: the peer closed this link (Chrome drops transport links
			// right after the referral relay). Raw recvmsg returns (0, nil)
			// forever on EOF, so without this branch the loop spins at 100%
			// CPU per referral and never runs the deferred fd close.
			return
		}
	}
}

// handleRequestIntroduction answers a child's (or the browser's) id=10 request:
// if we know the target node we perform a real broker introduction (link
// memory + socketpair + AcceptIntroduction to both sides); otherwise we reply
// RejectIntroduction so the requestor fails fast instead of hanging.
func handleRequestIntroduction(req *peer, data []byte, brokerName [16]byte) {
	if len(data) < 48 {
		log.Printf("intro: %x sent short RequestIntroduction (%d bytes)", req.name[:8], len(data))
		return
	}
	var target [16]byte
	copy(target[:], data[32:48])
	log.Printf("intro: %x -> introduction to %x", req.name[:8], target[:8])

	reject := func(reason string) {
		log.Printf("intro: rejecting %x -> %x (%s)", req.name[:8], target[:8], reason)
		if err := req.send(buildRejectIntroduction(target)); err != nil {
			log.Printf("intro: send RejectIntroduction to %x: %v", req.name[:8], err)
		}
	}

	if target == req.name {
		reject("self introduction")
		return
	}
	if target == brokerName {
		reject("target is the broker")
		return
	}
	tgt := lookupPeer(target)
	if tgt == nil {
		reject("unknown target node")
		return
	}
	go doIntroduce(req, tgt, target)
}

// doIntroduce performs the broker half of an introduction: one shared
// NodeLinkMemory buffer and one transport pair, then AcceptIntroduction (side
// A to the requestor, side B to the target) on each node's existing broker
// link. Afterwards the two nodes talk directly and we leave the path.
func doIntroduce(req, tgt *peer, target [16]byte) {
	key := introKey(req.name, tgt.name)
	if !introBegin(key) {
		log.Printf("intro: %x <-> %x already in progress/done, skipping", req.name[:8], tgt.name[:8])
		return
	}
	ok := false
	defer func() { introFinish(key, ok) }()

	rw, ro, err := makeLinkBuffer()
	if err != nil {
		log.Printf("intro: link buffer: %v", err)
		return
	}
	defer syscall.Close(rw)
	defer syscall.Close(ro)

	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		log.Printf("intro: socketpair: %v", err)
		return
	}
	endA, endB := pair[0], pair[1]
	defer syscall.Close(endA)
	defer syscall.Close(endB)

	// destination_type of each transport is the type of the node at its far
	// end; both sides here are non-brokers (kNormal = 1).
	toReq := buildAcceptIntroduction(target, 0 /* side A */, endpointTypeNonBroker,
		tgt.proto, rw, ro)
	toTgt := buildAcceptIntroduction(req.name, 1 /* side B */, endpointTypeNonBroker,
		req.proto, rw, ro)

	if err := req.send(toReq, endA, rw, ro); err != nil {
		log.Printf("intro: send AcceptIntroduction to %x: %v", req.name[:8], err)
		return
	}
	if err := tgt.send(toTgt, endB, rw, ro); err != nil {
		log.Printf("intro: send AcceptIntroduction to %x: %v", tgt.name[:8], err)
		return
	}
	ok = true
	log.Printf("intro: introduced %x <-> %x", req.name[:8], tgt.name[:8])
}

// buildRejectIntroduction assembles the id=12 message: params = {NodeName}.
func buildRejectIntroduction(name [16]byte) []byte {
	const paramsSize = 24
	msg := make([]byte, ipczHeaderSize+msgHeaderSize+paramsSize)
	data := msg[ipczHeaderSize:]
	binary.LittleEndian.PutUint16(msg[0:], ipczHeaderSize)
	binary.LittleEndian.PutUint16(msg[2:], 0) // no handles
	binary.LittleEndian.PutUint32(msg[4:], uint32(len(msg)))
	binary.LittleEndian.PutUint64(msg[8:], uint64(time.Now().UnixMicro()))
	data[0] = msgHeaderSize
	data[1] = 0
	data[2] = msgRejectIntroduction
	// driver_object_data_array stays 0: no driver objects.
	p := msgHeaderSize
	binary.LittleEndian.PutUint32(data[p:], paramsSize)
	copy(data[p+8:p+24], name[:])
	return msg
}

// buildAcceptIntroduction assembles the id=11 message with 2 driver objects:
// [transport(1 fd), sharedBuffer(rw + ro)].
//
// params: StructHeader(8) + V0{name(16) side(1) type(1) pad(2) proto(4)
// transport(4) memory(4)} + V1{remote_features(4)} = 44 content bytes rounded
// to 48: Message::ValidateParameters() requires the params struct header size
// to be 8-byte-aligned, and a 44 fails validation (which drops the link).
func buildAcceptIntroduction(name [16]byte, side uint8, remoteType, remoteProto uint32,
	rw, ro int) []byte {
	const paramsSize = 48
	objSizes := []int{16, 40} // transport, shared buffer

	off := msgHeaderSize
	paramsOff := off
	off += paramsSize

	off = align8(off)
	featOff := off
	off += 16 // ArrayHeader{16,1} + u64=0

	objOff := make([]int, 2)
	for i, sz := range objSizes {
		off = align8(off)
		objOff[i] = off
		off += 8 + sz
	}
	off = align8(off)
	dodOff := off
	off += 8 + 2*8

	msg := make([]byte, ipczHeaderSize+off)
	data := msg[ipczHeaderSize:]

	binary.LittleEndian.PutUint16(msg[0:], ipczHeaderSize)
	binary.LittleEndian.PutUint16(msg[2:], 3) // transport fd + buffer rw/ro
	binary.LittleEndian.PutUint32(msg[4:], uint32(len(msg)))
	binary.LittleEndian.PutUint64(msg[8:], uint64(time.Now().UnixMicro()))

	data[0] = msgHeaderSize
	data[1] = 0
	data[2] = msgAcceptIntroduction
	binary.LittleEndian.PutUint32(data[16:], uint32(dodOff))

	p := paramsOff
	binary.LittleEndian.PutUint32(data[p:], paramsSize)
	copy(data[p+8:p+24], name[:])
	data[p+24] = side
	data[p+25] = byte(remoteType)
	// data[p+26:p+28] = uint16 padding
	binary.LittleEndian.PutUint32(data[p+28:], remoteProto)
	binary.LittleEndian.PutUint32(data[p+32:], 0) // transport obj idx
	binary.LittleEndian.PutUint32(data[p+36:], 1) // memory obj idx
	binary.LittleEndian.PutUint32(data[p+40:], uint32(featOff))

	writeFeaturesArray(data, featOff)
	writeTransportObj(data, objOff[0], 16, remoteType)
	writeSharedBufferObj(data, objOff[1], 40, rw)

	binary.LittleEndian.PutUint32(data[dodOff:], 8+2*8)
	binary.LittleEndian.PutUint32(data[dodOff+4:], 2)
	binary.LittleEndian.PutUint32(data[dodOff+8:], uint32(objOff[0]))
	binary.LittleEndian.PutUint16(data[dodOff+12:], 0)
	binary.LittleEndian.PutUint16(data[dodOff+14:], 1)
	binary.LittleEndian.PutUint32(data[dodOff+16:], uint32(objOff[1]))
	binary.LittleEndian.PutUint16(data[dodOff+20:], 1)
	binary.LittleEndian.PutUint16(data[dodOff+22:], 2)

	_ = ro
	return msg
}

// driverObjectFD maps a driver object index to its first fd using the message's
// DriverObjectData array. Returns -1 if not found.
func driverObjectFD(data []byte, fds []int, objIdx uint32) int {
	if len(data) < 20 {
		return -1
	}
	dodOff := int(binary.LittleEndian.Uint32(data[16:20]))
	if dodOff == 0 || dodOff+8 > len(data) {
		return -1
	}
	numObjs := binary.LittleEndian.Uint32(data[dodOff+4:])
	if objIdx >= numObjs {
		return -1
	}
	entry := dodOff + 8 + int(objIdx)*8
	if entry+8 > len(data) {
		return -1
	}
	first := int(binary.LittleEndian.Uint16(data[entry+4:]))
	if first >= len(fds) {
		return -1
	}
	return fds[first]
}

// readTransportDestType reads the TransportHeader.destination_type of a driver
// object in a message. Layout at the object's driver_data_array offset:
// ArrayHeader(8) + ObjectHeader(8) + TransportHeader(destination_type u32).
func readTransportDestType(data []byte, objIdx uint32) uint32 {
	if len(data) < 20 {
		return endpointTypeNonBroker
	}
	dodOff := int(binary.LittleEndian.Uint32(data[16:20]))
	if dodOff == 0 || dodOff+8 > len(data) {
		return endpointTypeNonBroker
	}
	numObjs := binary.LittleEndian.Uint32(data[dodOff+4:])
	if objIdx >= numObjs {
		return endpointTypeNonBroker
	}
	entry := dodOff + 8 + int(objIdx)*8
	if entry+8 > len(data) {
		return endpointTypeNonBroker
	}
	arrOff := int(binary.LittleEndian.Uint32(data[entry:]))
	// destination_type at arrOff + 16 (ArrayHeader8 + ObjectHeader8)
	if arrOff+20 > len(data) {
		return endpointTypeNonBroker
	}
	return binary.LittleEndian.Uint32(data[arrOff+16:])
}

// makeSharedBuffer creates the initial handshake link buffer (rw + ro).
func makeSharedBuffer() (int, int, error) {
	return makeLinkBuffer()
}

// makeLinkBuffer creates a 128KiB NodeLinkMemory primary buffer: a fresh zeroed
// memfd initialized with next_buffer_id=1, next_sublink_id=kMaxInitialPortals,
// and each block allocator's free list terminated. Returns (rw, ro) fds.
func makeLinkBuffer() (int, int, error) {
	rw, err := unix.MemfdCreate("ash-link-buffer", 0)
	if err != nil {
		return -1, -1, err
	}
	if err := unix.Ftruncate(rw, primaryBufferSize); err != nil {
		unix.Close(rw)
		return -1, -1, err
	}
	// memfd reads as zeros. Initialize the primary buffer header + allocators.
	initPrimaryBuffer(rw)
	ro, err := unix.Open(fmt.Sprintf("/proc/self/fd/%d", rw), unix.O_RDONLY, 0)
	if err != nil {
		unix.Close(rw)
		return -1, -1, err
	}
	return rw, ro, nil
}

// initPrimaryBuffer writes the NodeLinkMemory primary-buffer header and
// terminates each block allocator's free list. The region is already zeroed
// (fresh memfd), which is the correct initial state: each block points to its
// successor. We only set the two header counters and the last block of each
// allocator region to point back to block 0.
func initPrimaryBuffer(rw int) {
	// PrimaryBufferHeader: next_buffer_id (u64 @0), next_sublink_id (u64 @8).
	hdr := make([]byte, 16)
	binary.LittleEndian.PutUint64(hdr[0:], 1)  // next_buffer_id = 1
	binary.LittleEndian.PutUint64(hdr[8:], 12) // next_sublink_id = kMaxInitialPortals
	unix.Pwrite(rw, hdr, 0)

	// Block allocator regions within the primary buffer. Each region is a
	// sequence of blocks; the last block's `next` (int16 at +2 in its 4-byte
	// header) is set to -(num_blocks) so it points back to block 0.
	// Layout offsets (256 header/pad + 768 initial_link_states = 1024 start):
	regions := []struct {
		base  int
		bsize int
		n     int
	}{
		{1024, 64, 1484},
		{1024 + 64*1484, 256, 9},
		{1024 + 64*1484 + 256*9, 512, 8},
		{1024 + 64*1484 + 256*9 + 512*8, 1024, 4},
		{1024 + 64*1484 + 256*9 + 512*8 + 1024*4, 2048, 4},
		{1024 + 64*1484 + 256*9 + 512*8 + 1024*4 + 2048*4, 4096, 4},
	}
	for _, r := range regions {
		last := r.base + r.bsize*(r.n-1)
		next := int16(-r.n) // points back to block 0 (relative to successor)
		nb := make([]byte, 2)
		binary.LittleEndian.PutUint16(nb, uint16(next))
		unix.Pwrite(rw, nb, int64(last+2))
	}
}

func randName() [16]byte {
	var n [16]byte
	rand.Read(n[:])
	return n
}

func parseFds(oob []byte) []int {
	var fds []int
	msgs, err := syscall.ParseSocketControlMessage(oob)
	if err != nil {
		return nil
	}
	for _, m := range msgs {
		got, err := syscall.ParseUnixRights(&m)
		if err != nil {
			continue
		}
		fds = append(fds, got...)
	}
	return fds
}

func closeFds(fds []int) {
	for _, fd := range fds {
		syscall.Close(fd)
	}
}
