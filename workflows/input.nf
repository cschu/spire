workflow manage_inputs {

	main:
	
	contigs_ch = Channel.empty()
	depths_ch = Channel.empty()
	reads_ch = Channel.empty()

	if (params.input_source == "sra") {
        if (params.NCBI_API_KEY == 'none') {
            input_samples = Channel
                .fromSRA(params.input_SRA_id)
                .dump(pretty:true, tag: "input_data")
        }
        else {
            input_samples = Channel
                .fromSRA(params.input_SRA_id, apiKey:params.NCBI_API_KEY)
                .dump(pretty:true, tag: "input_data")
        }

    } else if (params.input_source == "disk") {

        input_samples = Channel.fromPath("${params.input_dir}/**[._]{fastq.gz,fq.gz,fastq.bz2,fq.bz2}")			

        if (params.input_dir_structure == "flat") {
			input_samples = input_samples
				.map { file -> [ 
					file.getName()
						.replaceAll(/\.(fastq|fq)(\.(gz|bz2))?$/, "")
						.replaceAll(/[._]R?[12]$/, "")
						.replaceAll(/[._]singles$/, ""),
					file
				] }

		} else {
			input_samples = input_samples
				.map { file -> [ file.getParent().getName(), file ] }
		}

        reads_ch = input_samples
            .groupTuple(by: 0)
            .dump(pretty:true, tag: "input_data")

    } else if (params.input_source == "long_reads") {

		contigs_ch = Channel.fromPath(params.assembly_input + "/**.${params.suffix_pattern}")
        	.map { file -> return tuple(file.getParent().getName(), file) }

    	contigs_ch.dump(pretty: true, tag: "contigs_ch")
    
		depth_ch = Channel.fromPath(params.depth_input + "/**.tsv")
			.map { file -> return tuple(file.getParent().getName(), file) }

		depth_ch.dump(pretty: true, tag: "depth_ch")

	}

	emit:

	contigs = contigs_ch
	depths = depth_ch
	reads = reads_ch

}