_ = require 'underscore'
querystring = require 'querystring'
request = require 'request'
HtmlEntities = require('html-entities').AllHtmlEntities

@bind = (irene) ->
	irene.cmds.add 'run this :lang code :d*', (ctx, {lang, d}) =>
		d = d.replace(/^\s*```\s*|\s*```\s*$/g, '')

		switch lang.toLowerCase()
			when 'bash'
				stack = 'bash4'
				ext = 'sh'
			when 'c'
				stack = 'gcc4'
				ext = 'c'
			when 'c++'
				stack = 'g++4'
				ext = 'cpp'
			when 'java'
				stack = 'openjdk7'
				ext = 'java'
			when 'go'
				stack = 'go1'
				ext = 'go'
			when 'python'
				stack = 'python2'
				ext = 'py'
			else
				return

		await request
			method: 'post'
			url: "http://api.arturia.io/programs?secret=#{process.env.ARTURIA_SECRET}"
			json: {
				stack: stack,
				files: [
					name: "code.#{ext}"
					src: "data:base64,#{new Buffer(new HtmlEntities().decode d).toString('base64')}"
				]
				stdin:
					src: 'data:,'
				limits:
					cpu: 2*1e9
					memory: 33554432
			}
		, defer err, resp, body
		if err?
			return console.log err

		progId = body.id

		i = 32
		check = ->
			if i < 0
				return

			await request.get "http://api.arturia.io/programs/#{progId}?secret=#{process.env.ARTURIA_SECRET}", defer err, resp, body
			if err?
				return console.log err

			prog = JSON.parse body
			if prog.status is 'exited'
				await request.get prog.stdout.src, defer err, resp, body
				if err?
					return console.log err

				ctx.say "```#{body}```"
				return

			_.delay =>
				i--
				check()
			, 500

		check()
