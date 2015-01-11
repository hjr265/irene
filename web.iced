_ = require 'underscore'
express = require 'express'
Irene = require './irene'
mongoose = require 'mongoose'
moment = require 'moment'
request = require 'request'
spintax = require 'spintax'
slackNotify = require('slack-notify') process.env.SLACK_WEBHOOK_URL
Poll = require './models/poll'

mongoose.connect process.env.MONGO_URL or process.env.MONGOHQ_URL

irene = new Irene
await irene.initialize defer err
if err?
	throw err

app = express()

app
.use(require('morgan')('combined'))
.use(require('body-parser').urlencoded(extended: true))
.use(require('body-parser').json())

app.route('/api/do-standup')
.post((req, res, next) ->
	await irene.say process.env.SLACK_STANDUP_CHANNEL, '<!everyone> It\'s Standup Time! Can everyone answer these following few questions?\n1. What did you do yesterday?\n2. What do you plan on doing today?\n3. Is there anything you\'re blocked on?\n\nAlso, can you please make sure you\'ve updated the Trello board with what you\'re currently working on?', defer err
	if err?
		return next err
	res.end()
)

app.route('/api/do-standup-check')
.post((req, res, next) ->
	await request.get "https://slack.com/api/channels.list?token=#{process.env.SLACK_API_TOKEN}", defer err, resp, body
	if err?
		return console.log err

	body = JSON.parse body
	chan = _.findWhere body.channels, name: process.env.SLACK_STANDUP_CHANNEL.substr(1)

	users = []
	for id in chan.members
		await request.get "https://slack.com/api/users.info?token=#{process.env.SLACK_API_TOKEN}&user=#{id}", defer err, resp, body
		if err?
			return console.log err

		body = JSON.parse body
		user = body.user
		if user.deleted
			continue

		users.push user

	users = _.indexBy users, 'id'

	await request.get "https://slack.com/api/channels.history?token=#{process.env.SLACK_API_TOKEN}&channel=#{chan.id}", defer err, resp, body
	if err?
		return console.log err

	body = JSON.parse body
	msgs = body.messages

	hits = {}
	for msg in msgs
		if msg.hidden
			continue
		if msg.user is irene.self.id and msg.text.indexOf('It\'s Standup Time') >= 0
			break

		if msg.type is 'message' and users[msg.user]?
			for line in msg.text.split('\n')
				m = line.trim().match /^(\d+)\s*\.\s*[^\s]/
				if m?
					hits[msg.user] ?= {}
					hits[msg.user][m[1]] = yes

				m = line.trim().match /^(\d+)\s*\./
				if m?
					hits[msg.user] ?= {}
					hits[msg.user][m[1]+'_e'] = yes

	r = ''
	for id, user of users
		if id is irene.self.id
			continue

		hit = hits[id]
		if hit and hit['1'] and hit['2'] and hit['3'] or _.contains(process.env.STANDUP_EXCLUDE?.split(','), user.name)
			continue

		if r.length > 0
			r += ', '
		r += "<@#{user.name}>"

	if r is ''
		return res.end()

	r += spintax.unspin ': {Do not|Don\'t} make me ask{| you} again!'

	await irene.say process.env.SLACK_STANDUP_CHANNEL, r, defer err
	if err?
		return next err

	res.end()

	_.delay =>
		r = ''
		for id, user of users
			hit = hits[id]
			if hit and hit['1'] and hit['2'] and hit['3'] or _.contains(process.env.STANDUP_EXCLUDE?.split(','), user.name)
				continue

			if hit and hit['1_e'] and hit['2_e'] and hit['3_e']
				if r.length > 0
					r += ', '
				r += "<@#{user.name}>"

		if r is ''
			return

		r += ': You thought you could get away with this, didn\'t you?'

		await irene.say process.env.SLACK_STANDUP_CHANNEL, r, defer err
		if err?
			console.log err

	, 2000
)

app.route('/api/hooks/gitlab')
.post((req, res, next) ->
	
	hookType = req.body.object_kind
	author = req.body.user.name
	issueName = req.body.object_attributes.title
	issueURL = req.body.object_attributes.url
	assigneeId = req.body.object_attributes.assignee_id

	await request.get "#{process.env.GITLAB_URL}/users?private_token=#{process.env.GITLAB_API_TOKEN}&per_page=1000", defer err, resp, body

	if err?
		return console.log.err

	gitlabUsers = JSON.parse body
	userDetails = _.findWhere gitlabUsers, id: assigneeId

	username = userDetails.username

	await request.get "https://slack.com/api/users.list?token=#{process.env.SLACK_API_TOKEN}", defer err, resp, body
	if err?
		return console.log err

	body = JSON.parse body
	slackUser = _.findWhere body.members, name: username

	userId = slackUser.id

	switch hookType
		when 'issue'
			await irene.say "##{req.query.channel}", "#{author} assigned a new issue: \"#{issueName}\" to <@#{userId}|#{username}>. Details: #{issueURL}", defer err
			if err?
				return next err

		when 'merge_request'
			await irene.say "##{req.query.channel}", "<@#{userId}|#{username}>: You have a new merge request from #{author}", defer err
			if err?
				return next err

	res.end()
)

app.route('/api/do-birthday-wish')
.post((req, res, next) ->
	now = moment()
	birthdays = process.env.BIRTHDAYS?.split('|') or []
	for birthday in birthdays
		[userId, month, date] = birthday.split '-'
		if now.month()+1 is parseInt(month) and now.date() is parseInt(date)
			await request.get "https://slack.com/api/users.info?token=#{process.env.SLACK_API_TOKEN}&user=#{userId}", defer err, resp, body
			if err?
				return console.log err

			body = JSON.parse body
			user = body.user

			line = _.sample [
				'Getting older and growing up are two very different things.  One is still an option.'
				'The most frustrating thing about becoming an old cynical person is that it is difficult to blame someone for it happening.'
				'Some people try to hide their age by calling themselves mature or seniors, but I like being honest with old people.'
				'I wish I had remembered to get you a present.'
				'I wish you were older today... Oh, my wish came true! Happy birthday'
				'Wishing you enough air to blow out all of your candles. Happy Birthday'
				'Have the best birthday anyone could expect to have at your age'
				'Enjoy your senior citizen discounts. You deserve them. Happy birthday.'
				'I wish today was not your birthday... Because I forgot to get you a present.'
				'There\'s nothing funny about having a birthday and getting old when you ARE old.  That\'s why I am going to keep your birthday wishes totally serious.'
			]
			await irene.say '#general', "<@#{userId}|#{user.name}>: #{line}", defer err
			if err?
				return next err

	res.end()
)

app.route('/api/do')
.post((req, res, next) ->
	irene.do new Irene.Context req.body
	res.end()
)

app.route('/polls/:pollId/cands/:candKey/pick')
.get(({params, query}, res, next) ->
	await Poll.findById(params.pollId)
	.exec defer err, poll
	if err?
		return next err

	if not poll? or not poll.cands[params.candKey]?
		return res.send "Are you lost? Or trying to mess with my APIs?"

	if poll.closedAt?
		return res.send "The poll has been closed"

	voter = _.findWhere poll.voters, token: query.token
	if not voter?
		return res.send "Are you lost? Or trying to mess with my APIs?"

	prevVote = poll.votes[voter.id]
	poll.votes[voter.id] = params.candKey
	poll.markModified("votes.#{voter.id}")
	await poll.save defer err
	if err?
		return next err

	res.send "You picked \"#{poll.cands[params.candKey]}\""

	if not prevVote? and _.keys(poll.votes).length is poll.voters.length
		await request.get "https://slack.com/api/channels.info?token=#{process.env.SLACK_API_TOKEN}&channel=#{poll.chan}", defer err, res, body
		if err?
			return console.log err

		body = JSON.parse body
		chan = body.channel

		await request.get "https://slack.com/api/users.info?token=#{process.env.SLACK_API_TOKEN}&user=#{poll.createdBy}", defer err, res, body
		if err?
			return console.log err

		body = JSON.parse body
		user = body.user

		await irene.say chan.name, "<@#{user.name}>: All votes collected...", defer err
		if err?
			return console.log err
)

app.route('/')
.get((req, res) ->
	res.end()
)

await app.listen (port = process.env.PORT), defer err
if err?
	throw err

console.log "Listening on #{port}"
