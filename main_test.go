package nextdoor

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

/*
	func TestSmallCluster(t *testing.T) {
		t.Parallel()

		var nodes = make([]*Node, 10)
		for i := 0; i < 10; i++ {
			nodes[i] = NewNode("localhost:800"+strconv.Itoa(i), nil)
			fmt.Println("node ", i, nodes[i].ID, "localhost:800"+strconv.Itoa(i))
		}

		nTwo.AddPeer(nOne)
		for i := 0; i < 10; i++ {
			assert.NoError(t, nTwo.BroadcastNodeInfo())
			time.Sleep(time.Second)
		}
	}
*/
func TestMerge(t *testing.T) {
	var nOne = NewNode("localhost:8001", nil)
	var nTwo = NewNode("localhost:8002", nil)
	var nThree = NewNode("localhost:8003", nil)
	assert.Equal(t, 0, len(nOne.PeerData))
	assert.Equal(t, 0, len(nTwo.PeerData))
	assert.Equal(t, 0, len(nThree.PeerData))

	nTwo.AddPeer(*nThree)
	assert.Equal(t, 0, len(nOne.PeerData))
	assert.Equal(t, 1, len(nTwo.PeerData))
	assert.Equal(t, 0, len(nThree.PeerData))

	nOne.mergeNodes(*nTwo)
	assert.Equal(t, 2, len(nOne.PeerData))
	assert.Equal(t, 1, len(nTwo.PeerData))
	assert.Equal(t, 0, len(nThree.PeerData))

	assert.NoError(t, nOne.BroadcastNodeInfo())
	assert.Equal(t, 2, len(nOne.PeerData))
	assert.Equal(t, 2, len(nTwo.PeerData))
	assert.Equal(t, 2, len(nThree.PeerData))
}
