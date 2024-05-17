package nextdoor

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/google/uuid"
)

type Node struct {
	ID                 string
	MessageSequenceNum uint64
	Message            any
	HTTPAddr           string
	PeerData           map[string]Node
}

func NewNode(addr string, peers map[string]Node) *Node {
	var n = new(Node)
	n.ID = string(uuid.New().String())
	if peers == nil {
		n.PeerData = make(map[string]Node, 5)
	} else {
		n.PeerData = peers
	}
	n.HTTPAddr = "http://" + addr

	var mux = http.NewServeMux()
	mux.HandleFunc("/", n.gossipHandler)
	var server = &http.Server{
		Addr:           addr,
		Handler:        mux,
		ReadTimeout:    10 * time.Second,
		WriteTimeout:   10 * time.Second,
		MaxHeaderBytes: 1 << 20,
	}
	go func() {
		log.Fatal(server.ListenAndServe())
	}()

	return n
}

func (n *Node) AddPeer(peer Node) {
	n.PeerData[peer.ID] = peer
}

func (n *Node) BroadcastNodeInfo() error {

	n.Message = time.Now()
	n.MessageSequenceNum = n.MessageSequenceNum + 1

	nodeJSON, err := json.Marshal(n)
	if err != nil {
		return (err)
	}

	for _, peerData := range n.PeerData {

		resp, err := http.Post(peerData.HTTPAddr, "application/json", bytes.NewBuffer(nodeJSON))
		if err != nil {
			return (err)
		}

		if resp.StatusCode != http.StatusOK {
			return errors.New("did not get 200, got: " + resp.Status)
		}
	}

	return nil
}

func (n *Node) gossipHandler(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Error reading request body", http.StatusInternalServerError)
		return
	}

	var incomingNode Node
	if err := json.Unmarshal(body, &incomingNode); err != nil {
		http.Error(w, "Error parsing request body", http.StatusBadRequest)
		return
	}

	n.mergeNodes(incomingNode)

	// fmt.Printf("node: %s got message num: %d, message: %v, from node: %s \n", n.HTTPAddr, incomingNode.MessageSequenceNum, incomingNode.Message, incomingNode.HTTPAddr)

	w.WriteHeader(http.StatusOK)
}

// return values:
// 1. incomingNode gave us a newer value
// 2. we have a newer value than incomingNode
func (n *Node) mergeNodes(incomingNode Node) (bool, bool) {

	var receivedNewerValue, haveNewerValue bool

	// handle incoming peer's peers first
	for incomingID, incomingPeer := range incomingNode.PeerData {
		if incomingID == n.ID {
			continue // no need to add ourselves
		}

		if existingPeer, exists := n.PeerData[incomingID]; !exists {
			incomingPeer.PeerData = nil // we nil this because we dont want endless maps of peers
			n.PeerData[incomingID] = incomingPeer
			receivedNewerValue = true
		} else {
			if incomingPeer.MessageSequenceNum > existingPeer.MessageSequenceNum {
				var tempNode = n.PeerData[incomingID]
				tempNode.MessageSequenceNum = incomingPeer.MessageSequenceNum
				tempNode.Message = incomingPeer.Message
				n.PeerData[incomingID] = tempNode
				receivedNewerValue = true
			} else if incomingPeer.MessageSequenceNum < existingPeer.MessageSequenceNum {
				haveNewerValue = true
			}
		}
	}

	// handle incoming peer
	if _, exists := n.PeerData[incomingNode.ID]; !exists {
		incomingNode.PeerData = nil // we nil this because we dont want endless maps of peers
		n.PeerData[incomingNode.ID] = incomingNode
		receivedNewerValue = true
	} else {
		if incomingNode.MessageSequenceNum > n.PeerData[incomingNode.ID].MessageSequenceNum {
			var tempNode = n.PeerData[incomingNode.ID]
			tempNode.MessageSequenceNum = incomingNode.MessageSequenceNum
			tempNode.Message = incomingNode.Message
			n.PeerData[incomingNode.ID] = tempNode
			receivedNewerValue = true
		} else if incomingNode.MessageSequenceNum < n.PeerData[incomingNode.ID].MessageSequenceNum {
			haveNewerValue = true
		}
	}

	return receivedNewerValue, haveNewerValue
}
