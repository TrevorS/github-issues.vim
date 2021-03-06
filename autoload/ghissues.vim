" core is written in Python for easy JSON/HTTP support
" do not continue if Vim is not compiled with Python2.7 support
if !has("python") || exists("g:github_issues_pyloaded")
  finish
endif

python <<EOF
import os
import sys
import vim
import string
import json
import urllib2

# dictionaries for caching
# repo urls on github by filepath
github_repos = {}
# issues by repourl
github_datacache = {}
# api data by repourl + / + endpoint
api_cache = {}

# reset web cache after this value grows too large
cache_count = 0

# returns the Github url (i.e. jaxbot/vimfiles) for the current file
def getRepoURI():
  global github_repos

  if "gissues" in vim.current.buffer.name:
    s = getFilenameParens()
    return s[0] + "/" + s[1]

  # get the directory the current file is in
  filepath = vim.eval("shellescape(expand('%:p:h'))")

  if ".git" in filepath:
    filepath = filepath.replace(".git", "")

  # cache the github repo for performance
  if github_repos.get(filepath,'') != '':
    return github_repos[filepath]

  cmd = '(cd ' + filepath + ' && git remote -v)'

  filedata = os.popen(cmd).read()

  # possible URLs
  urls = vim.eval("g:github_issues_urls")
  for url in urls:
    s = filedata.split(url)
    if len(s) > 1:
      s = s[1].split()[0].split(".git")
      github_repos[filepath] = s[0]
      return s[0]
  return ""

# returns the repo uri, taking into account forks
def getUpstreamRepoURI():
  repourl = getRepoURI()
  if repourl == "":
    return ""

  upstream_issues = int(vim.eval("g:github_upstream_issues"))
  if upstream_issues == 1:
    # try to get from what repo forked
    repoinfo = ghApi("", repourl)
    if repoinfo and repoinfo["fork"]:
      repourl = repoinfo["source"]["full_name"]

  return repourl

# displays the issues in a vim buffer
def showIssueList(labels, ignore_cache = False):
  repourl = getUpstreamRepoURI()

  if repourl == "":
    print "Failed to find a suitable Github repository URL, sorry!"
    vim.command("let github_failed = 1")
    return

  if not vim.eval("g:github_same_window") == "1":
    vim.command("silent new")
  vim.command("noswapfile edit " + "gissues/" + repourl + "/issues")
  vim.command("normal ggdG")

  b = vim.current.buffer
  issues = getIssueList(repourl, labels, ignore_cache)

  cur_milestone = str(vim.eval("g:github_current_milestone"))

  # its an array, so dump these into the current (issues) buffer
  for issue in issues:
    if cur_milestone != "" and (not issue["milestone"] or issue["milestone"]["title"] != cur_milestone):
      continue

    issuestr = str(issue["number"]) + " " + issue["title"] + " "

    for label in issue["labels"]:
      issuestr += label["name"] + " "

    b.append(issuestr.encode(vim.eval("&encoding")))

  highlightColoredLabels(getLabels())

  # append leaves an unwanted beginning line. delete it.
  vim.command("1delete _")

def showMilestoneList(labels, ignore_cache = False):
  repourl = getUpstreamRepoURI()

  vim.command("silent new")
  vim.command("noswapfile edit " + "gissues/" + repourl + "/milestones")
  vim.command("normal ggdG")

  b = vim.current.buffer
  milestones = getMilestoneList(repourl, labels, ignore_cache)

  for mstone in milestones:
    mstonestr = str(mstone["number"]) + " " + mstone["title"]

    if mstone["due_on"]:
      mstonestr += " ("+mstone["due_on"]+")" # TODO: TZ formatting

    b.append(mstonestr.encode(vim.eval("&encoding")))

  vim.command("1delete _")

# pulls the issue array from the server
def getIssueList(repourl, query, ignore_cache = False):
  global github_datacache

  # non-string args correspond to vanilla issues request
  # strings default to label unless they correspond to a state
  params = {}
  if isinstance(query, basestring):
    params = { "label": query }
  if query in ["open", "closed", "all"]:
    params = { "state": query }

  return getGHList(ignore_cache, repourl, "/issues", params)

# pulls the milestone list from the server
def getMilestoneList(repourl, query = "", ignore_cache = False):
  global github_datacache

  # TODO Add support for 'state', 'sort', 'direction'
  params = {}

  return getGHList(ignore_cache, repourl, "/milestones", params)

def getGHList(ignore_cache, repourl, endpoint, params):
  global cache_count, github_datacache

  # Maybe initialise
  if github_datacache.get(repourl, '') == '' or len(github_datacache[repourl]) < 1:
    github_datacache[repourl] = {}

  if (ignore_cache or
      cache_count > 3 or
      github_datacache[repourl].get(endpoint,'') == '' or
      len(github_datacache[repourl][endpoint]) < 1):

    # load the github API. github_repo looks like "jaxbot/github-issues.vim", for ex.
    try:
      github_datacache[repourl][endpoint] = []
      more_to_load = True

      page = 1
      params['page'] = str(page)

      while more_to_load and page <= int(vim.eval("g:github_issues_max_pages")):

        # TODO This should be in ghUrl() I think
        qs = string.join([ k+'='+v for ( k, v ) in params.items()], '&')
        url = ghUrl(endpoint+'?'+qs, repourl)

        response = urllib2.urlopen(url)
        issuearray = json.loads(response.read())

        # JSON parse the API response, add page to previous pages if any
        github_datacache[repourl][endpoint] += issuearray

        more_to_load = len(issuearray) == 30

        page += 1

    except urllib2.URLError as e:
      github_datacache[repourl][endpoint] = []
      if e.code == 410 or e.code == 404:
        print "Error: Do you have a github_access_token defined?"

    cache_count = 0
  else:
    cache_count += 1

  return github_datacache[repourl][endpoint]

# adds issues, labels, and collaborators to omni dictionary
def populateOmniComplete():
  url = getUpstreamRepoURI()

  if url == "":
    return

  issues = getIssueList(url, 0)
  for issue in issues:
    addToOmni(str(issue["number"]) + " " + issue["title"])
  labels = getLabels()
  if labels:
    for label in labels:
      addToOmni(str(label["name"]))
  collaborators = getCollaborators()
  if collaborators:
    for collaborator in collaborators:
      addToOmni(str(collaborator["login"]))
  milestones = getMilestoneList(url)
  if milestones:
    for milestone in milestones:
      addToOmni(str(milestone["title"]))

# adds <keyword> to omni dictionary. used by populateOmniComplete
def addToOmni(keyword):
  vim.command("call add(b:omni_options, "+json.dumps(keyword)+")")

# simply opens a buffer based on repourl and issue <number>
def showIssueBuffer(number):
  repourl = getUpstreamRepoURI()
  if not vim.eval("g:github_same_window") == "1":
    vim.command("silent new")
  vim.command("edit gissues/" + repourl + "/" + number)

# show an issue buffer in detail
def showIssue():
  repourl = getUpstreamRepoURI()

  parens = getFilenameParens()
  number = parens[2]
  b = vim.current.buffer
  vim.command("normal ggdG")

  if number == "new":
    # new issue
    issue = { 'title': '',
      'body': '',
      'number': 'new',
      'user': {
        'login': ''
      },
      'assignee': '',
      'state': 'open',
      'labels': []
    }
  else:
    url = ghUrl("/issues/" + number)
    issue = json.loads(urllib2.urlopen(url).read())

  b.append("# " + issue["title"].encode(vim.eval("&encoding")) + " (" + str(issue["number"]) + ")")
  if issue["user"]["login"]:
    b.append("## Reported By: " + issue["user"]["login"].encode(vim.eval("&encoding")))

  b.append("## State: " + issue["state"])
  if issue['assignee']:
    b.append("## Assignee: " + issue["assignee"]["login"].encode(vim.eval("&encoding")))
  elif number == "new":
    b.append("## Assignee: ")

  if number == "new":
    b.append("## Milestone: ")
  elif issue['milestone']:
    b.append("## Milestone: " + str(issue["milestone"]["title"]))

  labelstr = ""
  if issue["labels"]:
    for label in issue["labels"]:
      labelstr += label["name"] + ", "
  b.append("## Labels: " + labelstr[:-2])

  if issue["body"]:
    b.append(issue["body"].encode(vim.eval("&encoding")).split("\n"))

  if number != "new":
    b.append("## Comments")

    url = ghUrl("/issues/" + number + "/comments")
    data = urllib2.urlopen(url).read()
    comments = json.loads(data)

    url = ghUrl("/issues/" + number + "/events")
    data = urllib2.urlopen(url).read()
    events = json.loads(data)

    events = comments + events

    if len(events) > 0:
      for event in events:
        b.append("")
        if "user" in event:
          user = event["user"]["login"]
        else:
          user = event["actor"]["login"]

        b.append(user.encode(vim.eval("&encoding")) + "(" + event["created_at"] + ")")

        if "body" in event:
          b.append(event["body"].encode(vim.eval("&encoding")).split("\n"))
        else:
          eventstr = event["event"].encode(vim.eval("&encoding"))
          if "commit_id" in event and event["commit_id"]:
            eventstr += " from " + event["commit_id"]
          b.append(eventstr)

    else:
      b.append("")
      b.append("No comments.")
      b.append("")

    b.append("## Add a comment")
    b.append("")

  vim.command("set ft=gfimarkdown")
  vim.command("normal ggdd")

  highlightColoredLabels(getLabels())

  # mark it as "saved"
  vim.command("setlocal nomodified")

# saves an issue and pushes it to the server
def saveGissue():
  parens = getFilenameParens()
  number = parens[2]

  issue = {
    'title': '',
    'body': '',
    'assignee': '',
    'labels': '',
    'milestone': ''
  }

  issue['title'] = vim.current.buffer[0].split("# ")[1].split(" (" + number + ")")[0]

  commentmode = 0

  comment = ""

  for line in vim.current.buffer[1:]:
    if commentmode == 1:
      if line == "## Add a comment":
        commentmode = 2
      continue
    if commentmode == 2:
      if line != "":
        commentmode = 3
        comment += line + "\n"
      continue
    if commentmode == 3:
      comment += line + "\n"
      continue

    if line == "## Comments":
      commentmode = 1
      continue
    if len(line.split("## Reported By:")) > 1:
      continue

    state = line.split("## State:")
    if len(state) > 1:
      if state[1].strip().lower() == "closed":
        issue['state'] = "closed"
      else: issue['state'] = "open"
      continue

    milestone = line.split("## Milestone:")
    if len(milestone) > 1:
      milestones = getMilestoneList(parens[0] + "/" + parens[1], "")

      milestone = milestone[1].strip()

      for mstone in milestones:
        if mstone["title"] == milestone:
          issue['milestone'] = str(mstone["number"])
          break
      continue

    labels = line.split("## Labels:")
    if len(labels) > 1:
      issue['labels'] = labels[1].lstrip().split(', ')
      continue

    assignee = line.split("## Assignee:")
    if len(assignee) > 1:
      issue['assignee'] = assignee[1].strip()
      continue

    if issue['body'] != '':
      issue['body'] += '\n'
    issue['body'] += line

  # remove blank entries
  issue['labels'] = filter(bool, issue['labels'])

  if issue.get('labels', '') != '' and issue['labels'] == '':
    del issue['labels']
  if issue.get('body', '') != '' and issue['body'] == '':
    del issue['body']
  if issue.get('assignee', '') != '' and issue['assignee'] == '':
    del issue['assignee']

  if number == "new":
    try:
      url = ghUrl("/issues")
      request = urllib2.Request(url, json.dumps(issue))
      data = json.loads(urllib2.urlopen(request).read())
      parens[2] = str(data['number'])
      vim.current.buffer.name = "gissues/" + parens[0] + "/" + parens[1] + "/" + parens[2]
    except urllib2.HTTPError as e:
      if e.code == 410 or e.code == 404:
        print "Error creating issue. Do you have a github_access_token defined?"
      else:
        print "Unknown HTTP error:"
        print e
  else:
    url = ghUrl("/issues/" + number)
    request = urllib2.Request(url, json.dumps(issue))
    request.get_method = lambda: 'PATCH'
    try:
      urllib2.urlopen(request)
    except urllib2.HTTPError as e:
      if e.code == 410 or e.code == 404:
        print "Could not update the issue as it does not belong to you"

  if commentmode == 3:
    try:
      url = ghUrl("/issues/" + parens[2] + "/comments")
      data = json.dumps({ 'body': comment })
      request = urllib2.Request(url, data)
      urllib2.urlopen(request)
    except urllib2.HTTPError as e:
      if e.code == 410 or e.code == 404:
        print "Could not post comment. Do you have a github_access_token defined?"

  if commentmode == 3 or number == "new":
    showIssue()

  # mark it as "saved"
  vim.command("setlocal nomodified")

# updates an issues data, such as opening/closing
def setIssueData(issue):
  parens = getFilenameParens()
  url = ghUrl("/issues/" + parens[2])
  request = urllib2.Request(url, json.dumps(issue))
  request.get_method = lambda: 'PATCH'
  urllib2.urlopen(request)

  showIssue()

def getLabels():
  return ghApi("/labels")

def getCollaborators():
  return ghApi("/collaborators")

# adds labels to the match system
def highlightColoredLabels(labels):
  if not labels:
    labels = []

  labels.append({ 'name': 'closed', 'color': 'ff0000'})
  labels.append({ 'name': 'open', 'color': '00aa00'})

  for label in labels:
    vim.command("hi issueColor" + label["color"] + " guifg=#ffffff guibg=#" + label["color"])
    vim.command("let m = matchadd(\"issueColor" + label["color"] + "\", \"\\\\<" + label["name"] + "\\\\>\")")

# queries the ghApi for <endpoint>
def ghApi(endpoint, repourl = False, cache = True):
  if not repourl:
    repourl = getUpstreamRepoURI()

  if cache and api_cache.get(repourl + "/" + endpoint):
    return api_cache[repourl + "/" + endpoint]

  try:
    req = urllib2.urlopen(ghUrl(endpoint, repourl), timeout = 5)
    data = json.loads(req.read())

    api_cache[repourl + "/" + endpoint] = data

    return data
  except:
    print "An error occurred. If this is a private repo, make sure you have a github_access_token defined"
    return None

# generates a github URL, including access token
def ghUrl(endpoint, repourl = False):
  params = ""
  token = vim.eval("g:github_access_token")
  if token:
    if "?" in endpoint:
      params = "&"
    else:
      params = "?"
    params += "access_token=" + token
  if not repourl:
    repourl = getUpstreamRepoURI()

  return vim.eval("g:github_api_url") + "repos/" + urllib2.quote(repourl) + endpoint + params

# returns an array of parens after gissues in filename
def getFilenameParens():
  return vim.current.buffer.name.replace("\\", "/").split("gissues/")[1].split("/")

EOF

function! ghissues#init()
  let g:github_issues_pyloaded = 1
endfunction

" vim: softtabstop=2 expandtab shiftwidth=2 tabstop=2
