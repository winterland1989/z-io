



counterNode :: Node x x Int
counterNode = Node (newCounter)



data TumblingWindowState =
tumblingWindowNode :: Node x [x] TumblingWindowState

data HoppingWindowState =
hoppingWindowNode :: Node x [x] HoppingWindowState

data SlidingWindowState =
slidingWindowNode :: Node x [x] SlidingWindowState

data SessionWindowState =
sessionWindowNode :: Node x [x] SessionWindowState