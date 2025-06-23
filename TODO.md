# TODO

## Features

- [-] Bookmark catalog
	- [-] Download bookmarks
		- [ ] Show a menu only with the downloaded bookmarks
		- [x] Only download new bookmarks, else, simply open the local copy
	- [-] Cache a bookmark list locally, for browsing when offline
		- [ ] Option to clean cache
	- [ ] Avoid entering in submenu when it would be empty
	- [ ] Search bookmarks from all collections, or only the current collection/submenu
	- [x] List by labels
		- [ ] Search labels
	- [x] List collections
- [ ] Bookmarks sync
	- [-] Sync reading progress
	- [ ] Sync highlights (with colors)
	- [ ] Option to archive or mark as favorite while reading (and push when online)
	- [-] Add bookmark links to Readeck while reading
		- [x] when online
		- [ ] when offline, add bookmark to "push queue" until online
		- [ ] Option (with configurable defaults) to download the new bookmark,
			mark as finished, mark as archived (like in the browser extension)
		- [ ] Option to immediately open the new bookmark
	- [ ] Settings: similar to the ones provided by kosync.koplugin
- [-] Configuration menu
	- [x] Logging in
	- [x] Option to set default labels (e.g.: "from kindle")
	- [ ] More settings...?
- [ ] Delete downloaded bookmarks
	- [ ] Button to delete all/read/archived bookmarks
	- [ ] Hold a bookmark in the browser to allow deletion
- [-] Improve internet connection callbacks... a lot

## Bugs

- [x] On Kindle (not on PC), text input fields automatically fill up with some text
	about reporting bugs via email.
- [x] Don't crash when certain operations are done without network...
