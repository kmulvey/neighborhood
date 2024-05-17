package nextdoor

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
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
		return err
	}

	for _, peerData := range n.PeerData {
		resp, err := http.Post(peerData.HTTPAddr, "application/json", bytes.NewBuffer(nodeJSON))
		if err != nil {
			return err
		}

		if resp.StatusCode != http.StatusOK {
			return errors.New("did not get 200, got: " + resp.Status)
		}

		// the node we just sent to could of had newer data than us, lets update
		incomingNode, err := parseRequestBody(resp.Body)
		if err != nil {
			return err
		}

		n.mergeNodes(incomingNode)
	}

	return nil
}

func parseRequestBody(body io.ReadCloser) (Node, error) {
	var incomingNode Node

	bodyBytes, err := io.ReadAll(body)
	if err != nil {
		return incomingNode, fmt.Errorf("error reading request body, err: %w", err)
	}

	if err := json.Unmarshal(bodyBytes, &incomingNode); err != nil {
		return incomingNode, fmt.Errorf("error parsing request body, err: %w", err)
	}

	return incomingNode, nil
}

// return 201 means we got updated
// return 200 means we were already up to date
func (n *Node) gossipHandler(w http.ResponseWriter, r *http.Request) {
	var incomingNode, err = parseRequestBody(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	var receivedNewerValue, haveNewerValue = n.mergeNodes(incomingNode)
	// if we have newer data that the sender doesnt, than lets tell them
	if haveNewerValue {
		n.Message = time.Now()
		n.MessageSequenceNum = n.MessageSequenceNum + 1

		nodeJSON, err := json.Marshal(n)
		if err != nil {
			http.Error(w, "Error marshaling node data to json: "+err.Error(), http.StatusInternalServerError)
			return
		}
		if _, err := w.Write(nodeJSON); err != nil {
			http.Error(w, "Error sending back node data: "+err.Error(), http.StatusInternalServerError)
			return
		}
	}

	if receivedNewerValue {
		w.WriteHeader(http.StatusCreated)
	} else {
		w.WriteHeader(http.StatusOK)
	}
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
