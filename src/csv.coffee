module.exports = class CSV

	constructor: (@settings={}) ->
		@_init()
		@settings.trim ?= true
		@settings.exclude_bad_rows ?= false
		@settings.allow_single_column ?= false
		@settings.unknown_column_name ?= 'Unknown'

	_init: ->
		@_columns = []
		@_rows = []
		@_stats =
			line_ending: 'Unknown'
			delimiter: 'Unknown'
			row_count: 0
			bad_row_indexes: []
			valid_column_count: 0
			blank_column_count: 0
			added_column_count: 0
			total_column_count: 0

	getStats: -> @_stats
	getColumns: -> @_columns
	getRow: (i) ->
		i = @getRowCount() + i if i < 0
		return null unless @_rows[i]?
		return @_rows[i]
	getRows: -> @_rows
	getRowCount: -> @_rows.length
	getObject: (i) ->
		row = @getRow(i)
		return null unless row?
		ob = {}
		for column, j in @_columns
			ob[column] = row[j] if row[j]?
		return ob
	getObjects: -> (@getObject(i) for i in [0...@getRowCount()])

	readFile: (path, callback) ->
		data = ''
		stream = require('fs').createReadStream(path)
			.on 'data', (chunk) ->
				data += chunk
			.on 'error', (err) ->
				callback?(err)
			.on 'end', =>
				@parse data, (err, stats) ->
					callback?(err, stats)

	parse: (data, callback) ->
		@_init()

		# column name generator
		generated_col_count = 0
		getNextColumnName = =>
			generated_col_count++
			i = 1
			loop
				col_name = "#{@settings.unknown_column_name} #{i++}"
				return col_name unless col_name in @_columns

		# detect line ending
		line_ending = '\n'
		ending_count = 0
		data = data.trim()
		for name, ending of {'Windows': '\r\n', 'Unix': '\n', 'Mac': '\r'}
			count = data.match(new RegExp(ending, 'g'))?.length
			if count > ending_count
				ending_count = count
				line_ending = ending
				@_stats.line_ending = name
		data = data.split(line_ending)
		return callback('Line ending detection failed') unless data.length > 1
		cols = data.shift().trim()

		# detect delimiter
		char_count = {}
		for type, char of {commas: ',', pipes: '|', tabs: '\t'}
			char_count[type] = (cols + '').split(char).length - 1
		delimiter = '\t'
		delimiter = ',' if char_count.commas > char_count.tabs
		delimiter = '|' if char_count.commas < char_count.pipes > char_count.tabs
		cols = cols.split(delimiter)
		return callback('Delimiter detection failed') unless cols.length > 1 or @settings.allow_single_column is true
		@_stats.delimiter = switch delimiter
			when ',' then 'Comma'
			when '|' then 'Pipe'
			when '\t' then 'Tab'
		cols.pop() while cols[cols.length - 1] is ''
		col_count = cols.length
		@_columns = cols

		# detect columns
		for val, i in cols
			val = val.replace(/^"|"$/g, '').trim()
			if val is ''
				cols[i] = getNextColumnName()
			else cols[i] = val
		return callback('Column names not found') if generated_col_count / col_count >= .5
		@_stats.valid_column_count = col_count
		@_stats.blank_column_count = generated_col_count

		# parse rows
		bad_rows = []
		min_field_count = null
		max_field_count = 0
		for line, line_index in data

			# parse row
			row = line.split(delimiter)
			starts = []
			ends = []
			seek = false
			for val, i in row
				start = false
				end = false
				v = val.trim()
				if not seek and (v.match(/^"/)? and not v.match(/^""[^"]/)?) and (not v.match(/"$/)? or v.match(/[^"]""$/)?) and not v.match(/[^"]{3}"[^"]{3}/)?
					start = true
					seek = true
					starts.push i
				if seek and (v.match(/"$/)? and not v.match(/[^"]""$/)?) and (not v.match(/^"/)? or v.match(/^""[^"]/)?)
					end = true
					seek = false
					ends.push i
				if v in ['"', '"""']
					if seek
						ends.push i
					else starts.push i
					seek = not seek
				quoted = v.match(/^"/)? and v.match(/"$/)?
				val = val.replace(/^"/, '') if start or quoted
				val = val.replace(/"$/, '') if end or quoted
				row[i] = val

			# join quoted fields
			if starts.length > 0
				new_row = []
				index = 0
				for start_index, i in starts
					end_index = ends[i]
					new_row.push row[j] for j in [index...start_index]
					index = end_index + 1
					new_row.push row.slice(start_index, end_index + 1).join(delimiter)
				new_row.push row[j] for j in [index...row.length]
				row = new_row

			# finalize row
			row[i] = val.replace(/""/g, '"') for val, i in row
			row.pop() while row.length > col_count and row[row.length - 1] is ''
			row.push '' while row.length < col_count
			if @settings.trim is true
				row[i] = val.trim() for val, i in row

			# handle bad row
			allow_row = true
			if row.length > col_count
				bad_rows.push row
				@_stats.bad_row_indexes.push line_index
				allow_row = false if @settings.exclude_bad_rows is true

			# add row
			if allow_row
				@_rows.push row
				min_field_count = row.length if not max_field_count? or row.length < min_field_count
				max_field_count = row.length if row.length > max_field_count

		# handle bad rows
		cols.push getNextColumnName() while max_field_count > cols.length
		return callback('Too many unknown columns') if generated_col_count / col_count >= .5
		if bad_rows.length is @_rows.length
			@_stats.bad_row_indexes.length = 0
			@_rows = bad_rows if @settings.exclude_bad_rows is true
		if @settings.exclude_bad_rows isnt true and max_field_count > min_field_count
			for row in @_rows
				row.push '' while row.length < max_field_count

		# stats
		@_stats.added_column_count = generated_col_count - @_stats.blank_column_count
		@_stats.total_column_count = cols.length
		@_stats.row_count = @_rows.length
		callback(null, @_stats)