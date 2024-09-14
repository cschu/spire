#!/usr/bin/env nextflow
 
process preprocess_fastqs {
    publishDir "${params.outdir}/${sample_id}/filtering/${sample_id}", mode: "copy"

    input:
    tuple val(sample_id), path(fastq_files)

    output:
    tuple val(sample_id), path("${sample_id}/${sample_id}.filtered.*fq.gz"), emit: filtered
    path("${sample_id}_read_count_after_qc.txt"), emit: counts

    script:
    """
    export HOME=./
    mkdir ${sample_id}
    mv $fastq_files ${sample_id}

    create_ngless_template_files.py -r ${params.NGLESS_REFERENCE}
    ngless -t ./ raw_data_filter.ngl -j ${task.cpus} ./ ${sample_id}
    cat raw_data_filter.ngl.output_ngless/fq.tsv > ${sample_id}_read_count_after_qc.txt
    """
}

process assembly {
    publishDir "${params.outdir}/${sample_id}/assemblies/", mode: "copy"

    input:
    tuple val(sample_id), path('*')

    output:
    tuple val(sample_id), file("${sample_id}-assembled.fa.gz"), optional: true

    script:
    """
    if [ -f "${sample_id}.filtered.pair.2.fq.gz" ]; then
        read_args="-1 ${sample_id}.filtered.pair.1.fq.gz -2 ${sample_id}.filtered.pair.2.fq.gz"
        if [ -f "${sample_id}.filtered.singles.fq.gz" ]; then
                read_args="\${read_args} -r ${sample_id}.filtered.singles.fq.gz"
        fi
    elif [ -f "${sample_id}.filtered.pair.1.fq.gz" ]; then
        read_args="-r ${sample_id}.filtered.pair.1.fq.gz"
    elif  [ -f "${sample_id}.filtered.singles.fq.gz" ]; then
        read_args="-r ${sample_id}.filtered.singles.fq.gz"
    elif  [ -f "${sample_id}.filtered.fq.gz" ]; then
        read_args="-r ${sample_id}.filtered.fq.gz"
    fi

    megahit -m ${task.memory.toBytes()} \
            --mem-flag 0 \
            -t ${task.cpus} \
             \$read_args \
            -o megahit_out
    mv megahit_out/final.contigs.fa ${sample_id}-assembled.fa
    if [ -s "${sample_id}-assembled.fa" ]; then
        gzip ${sample_id}-assembled.fa
    else
        echo "[INFO] ASSEMBLY EMPTY"
        rm ${sample_id}-assembled.fa
    fi
    """
}

process gene_calling_prodigal {
    publishDir "${params.outdir}/${sample_id}/prodigal/", mode: "copy"
    
    input:
    tuple val(sample_id), file(unfiltered_assembly)

    output:
    tuple val(sample_id), path("${sample_id}.${params.assemblytype}.prodigal.faa.gz"), emit: genecalls_faa
    tuple val(sample_id), path("${sample_id}.${params.assemblytype}.prodigal.fna.gz"), emit: genecalls_fna
    path("${sample_id}.${params.assemblytype}.prodigal.gff.gz")

    script:
    def sample_basename = "${sample_id}.${params.assemblytype}.prodigal"
    """
    zcat ${unfiltered_assembly} | prodigal -o ${sample_basename}.gff -f gff -q -p meta -a ${sample_basename}.faa -d ${sample_basename}.fna
    wait
    gzip ${sample_basename}.fna
    gzip ${sample_basename}.faa
    gzip ${sample_basename}.gff
    """

}

process remove_small_contigs {

    input:
    tuple val(sample_id), file(unfiltered_assembly)

    output:
    tuple val(sample_id), file("${unfiltered_assembly.getBaseName()}.filtered.fasta"), optional: true

    script:
    """
    seqtk seq -L 1000 ${unfiltered_assembly} > ${unfiltered_assembly.getBaseName()}.filtered.fasta
    if ! [ -s "${unfiltered_assembly.getBaseName()}.filtered.fasta" ]; then
        rm ${unfiltered_assembly.getBaseName()}.filtered.fasta
    fi
    """
}

process index {

    input:
    tuple val(sample_id), file(assembly)

    output:
    tuple val(sample_id), file("${assembly}.*")

    script:
    """
    bwa index ${assembly}
    """
}

process alignment {

    input:
    tuple val(sample_id),  file('*'), file('*'), file('*')

    output:
    tuple val(sample_id), file("output.bam")

    script:
    """
    if [ -f "${sample_id}.filtered.pair.2.fq.gz" ]; then
        read_pair="${sample_id}.filtered.pair.1.fq.gz ${sample_id}.filtered.pair.2.fq.gz"
        bwa mem -v 2 -t 8 ${sample_id}-assembled.fa.filtered.fasta \${read_pair} | samtools view -hb -u -F 4 -  | samtools sort -@4  > tmp_paired.bam &

        if [ -f "${sample_id}.filtered.singles.fq.gz" ]; then
            bwa mem -v 2 -t 8 ${sample_id}-assembled.fa.filtered.fasta ${sample_id}.filtered.singles.fq.gz | samtools view -hb -u -F 4 -  | samtools sort -@4 > tmp_singles.bam &
            wait
            samtools merge output.bam tmp_paired.bam tmp_singles.bam
        else
            wait
            mv tmp_paired.bam output.bam
        fi
    elif [ -f "${sample_id}.filtered.pair.1.fq.gz" ]; then
        bwa mem -v 2 -t 8 ${sample_id}-assembled.fa.filtered.fasta ${sample_id}.filtered.pair.1.fq.gz | samtools view -hb -u -F 4 -  | samtools sort -@4 > output.bam

    elif  [ -f "${sample_id}.filtered.singles.fq.gz" ]; then
        bwa mem -v 2 -t 8 ${sample_id}-assembled.fa.filtered.fasta ${sample_id}.filtered.singles.fq.gz | samtools view -hb -u -F 4 -  | samtools sort -@4 > output.bam

    elif  [ -f "${sample_id}.filtered.fq.gz" ]; then
        bwa mem -v 2 -t 8 ${sample_id}-assembled.fa.filtered.fasta ${sample_id}.filtered.fq.gz | samtools view -hb -u -F 4 -  | samtools sort -@4 > output.bam

    fi
    if ! [ -s "output.bam" ]; then
        rm output.bam
    fi
    """
}

process depths {
    publishDir "${params.outdir}/${sample_id}/bins/", mode: "copy"

    input:
    tuple val(sample_id), file(bam_file)

    output:
    tuple val(sample_id), file("${sample_id}_aligned_to_${sample_id}.depths")

    script:
    """
    jgi_summarize_bam_contig_depths --outputDepth ${sample_id}_aligned_to_${sample_id}.depths ${bam_file}
    """
}

process binning {
    publishDir "${params.outdir}/${sample_id}/", mode: "copy"

    input:
    tuple val(sample_id), file(depthfile), file(assembly_file)

    output:
    tuple val(sample_id), path("bins/*")

    script:
    def sample_basename = "${sample_id}.${params.assemblytype}.${params.bintype}"
            //  -i ${sample_id}-assembled.fa.filtered.fasta \
    """
    metabat2 --verbose \
             -i ${assembly_file} \
             -a ${depthfile} \
             -t 4 \
             --seed 1987 \
             -o ${sample_id}.bin
    wait 
    if [ "*bin.*.fa" ]; then
        mkdir bins
        for i in *bin.*.fa; do
            filename=\$(basename \$i)
            bin_number=\${filename#*bin.}
            bin_number=\${bin_number%.fa}
            padded_bin_number=\$(printf "%05d" \$bin_number)
            mv "\$i" bins/"${sample_basename}.\${padded_bin_number}.fa"
            gzip bins/"${sample_basename}.\${padded_bin_number}.fa"
        done
    fi
    # for i in *bin.*.fa;
    #     do bin_number=`echo \$i | grep -oP '(?<=bin\\.)\\d+(?=\\.fa)'`;
    #     padded_bin_number=`printf "%05d" \$bin_number`;
    #     mv \$i ${sample_basename}.\${padded_bin_number}.fa
    #     gzip ${sample_basename}.\${padded_bin_number}.fa
    # done
    """
}

process per_bin_genecalling {
    publishDir "${params.outdir}/${sample_id}/per_bin_genecalls/", mode: "copy"

    input:
    tuple val(sample_id), file('bins/*'), file(genecalls_faa), file(genecalls_fna)

    output:
    tuple val(sample_id), file("${sample_id}/*"), emit: bincalls

    script:
    //   cat genecalls_extracted.faa.ids | grep -f \${bin_id}.contig.names | cut -c2- | cut -f1 -d" " > \${bin_id}.faa.gene_names
    //   cat genecalls_extracted.fna.ids | grep -f \${bin_id}.contig.names | cut -c2- | cut -f1 -d" " > \${bin_id}.fna.gene_names
    """
    mkdir ${sample_id}

    gzip -dc ${genecalls_faa} > genecalls_extracted.faa
    gzip -dc ${genecalls_fna} > genecalls_extracted.fna

    grep "^>" genecalls_extracted.faa | cut -c2- | cut -f1 -d" " > genecalls_extracted.faa.ids
    grep "^>" genecalls_extracted.fna | cut -c2- | cut -f1 -d" " > genecalls_extracted.fna.ids

    for bin in bins/*
    do
      bin_id=\${bin:5:\${#bin}-11}

      ## Get all contig names in bin
      zcat \$bin | grep ">" | cut -c2- | cut -d " " -f1 | sed -e 's/\$/_/' > \${bin_id}.contig.names

      ## Get all genenames contining bin names
      grep -F -f \${bin_id}.contig.names genecalls_extracted.faa.ids > \${bin_id}.faa.gene_names
      grep -F -f \${bin_id}.contig.names genecalls_extracted.fna.ids > \${bin_id}.fna.gene_names

      ## Get all sequences with genenames in fasta_search
      seqtk subseq -l 60 genecalls_extracted.faa \${bin_id}.faa.gene_names > ${sample_id}/\${bin_id}.extracted.faa
      seqtk subseq -l 60 genecalls_extracted.fna \${bin_id}.fna.gene_names > ${sample_id}/\${bin_id}.extracted.fna
    done
    for x in ${sample_id}/*;
    do
      if ! [ -s "\$x" ]; then
          echo \$x >> ${sample_id}/bins_with_no_genes.txt
          rm \$x
      fi
    done

    rm -rvf genecalls_extracted.faa genecalls_extracted.fna genecalls_extracted.faa.ids genecalls_extracted.fna.ids
    """
}

process assembly_stats {
    publishDir "${params.outdir}/${sample_id}/assembly_stats/", mode: "copy"

    input:
    tuple val(sample_id), file(unfiltered_assembly)

    output:
    file "${sample_id}.assembly_stats.tsv"

    script:

    """
    zcat ${unfiltered_assembly} > ${sample_id}-assembled.fa
    assembly-stats -t ${sample_id}-assembled.fa > ${sample_id}.assembly_stats.tsv
    """
}

process assembly_mash_sketching {
    publishDir "${params.outdir}/${sample_id}/assembly_mash_sketching/", mode: "copy"

    input:
    tuple val(sample_id), file(unfiltered_assembly)

    output:
    file "${sample_id}-assembled.fa.gz.msh"

    script:

    """
    mash sketch -s 10000 -S 1987 -o ${sample_id}-assembled.fa.gz.msh ${unfiltered_assembly}
    """
}

process bin_mash_sketching {
    publishDir "${params.outdir}/${sample_id}/bin_mash_sketching/", mode: "copy"

    input:
    tuple val(sample_id), file('bins/*')

    output:
    file("${sample_id}/*")

    script:
    """
    mkdir ${sample_id}
    for bin in bins/*
    do
      bin_id=\${bin:5:\${#bin}-8}
      mash sketch -s 10000 -S 1987 -o ${sample_id}/\${bin_id}.msh \$bin
    done
    """
}

process rrna_detection {
    publishDir "${params.outdir}/${sample_id}/rrna/", mode: "copy"

    input:
    tuple val(sample_id), file(unfiltered_assembly)

    output:
    file "${sample_id}/*"

    script:

    """
    mkdir ${sample_id}
    zcat ${unfiltered_assembly} > uncompressed_assembly.fa
    barrnap --kingdom bac uncompressed_assembly.fa > ${sample_id}/${sample_id}-barrnap.bac.gff
    barrnap --kingdom arc uncompressed_assembly.fa > ${sample_id}/${sample_id}-barrnap.arc.gff
    barrnap --kingdom euk uncompressed_assembly.fa > ${sample_id}/${sample_id}-barrnap.euk.gff
    barrnap --kingdom mito uncompressed_assembly.fa > ${sample_id}/${sample_id}-barrnap.mito.gff
    """
}


process abricate {
    publishDir "${params.outdir}/${sample_id}/abricate/", mode: "copy"

    input:
    tuple val(sample_id), file(genecalls_fna)

    output:
    file("${sample_id}.${params.assemblytype}.abricate.vfdb.tsv")
    file("${sample_id}.${params.assemblytype}.abricate.megares.tsv")

    script:

    """
    abricate ${genecalls_fna} --db vfdb > ${sample_id}.${params.assemblytype}.abricate.vfdb.tsv
    abricate ${genecalls_fna} --db megares > ${sample_id}.${params.assemblytype}.abricate.megares.tsv
    """
}

process macrel {
    publishDir "${params.outdir}/${sample_id}/macrel/", mode: "copy"

    input:
    tuple val(sample_id), file(unfiltered_assembly)

    output:
    file "${sample_id}.smorfs.faa"

    script:
    """
    macrel get-smorfs --keep-fasta-headers --fasta $unfiltered_assembly --file-output ${sample_id}.smorfs.faa
    """

}

process gunc {
    publishDir "${params.outdir}/${sample_id}/gunc/", mode: "copy"

    input:
    tuple val(sample_id), path('bins/*')

    output:
    file("${sample_id}.GUNC.maxCSS_level.tsv")
    file("${sample_id}.GUNC.maxCSS_level_gunc5.tsv")
    file("${sample_id}.GUNC.all_levels/*")

    script:
    """
    gunc run -d bins -e .fa.gz -v --detailed_output
    mv gunc_output ${sample_id}.GUNC.all_levels
    mv GUNC.progenomes_2.1.maxCSS_level.tsv ${sample_id}.GUNC.maxCSS_level.tsv
    add_gunc5_score.py -m ${sample_id}.GUNC.maxCSS_level.tsv -d ${sample_id}.GUNC.all_levels -o ${sample_id}.GUNC.maxCSS_level_gunc5.tsv
    sleep 2
    """
}

process eggnog_mapper {
    publishDir "${params.outdir}/${sample_id}/eggnog_mapper/", mode: "copy"

    input:
    tuple val(sample_id), file(gene_calls)

    output:
    file "${sample_id}.emapper.annotations.gz"
    file "${sample_id}.emapper.seed_orthologs.gz"
    file "${sample_id}.emapper.hits.gz"

    script:
    """
    cp -R ${params.EGGNOG_DATA_DIR} ./
    export EGGNOG_DATA_DIR='./5.0.2/'
    zcat ${gene_calls} > ${sample_id}.genecalls.faa
    emapper.py -i ${sample_id}.genecalls.faa --output ${sample_id} --dbmem -m diamond --cpu ${task.cpus} --tax_scope prokaryota_broad

    if [[ -s ${sample_id}.emapper.pfam ]]
    then
        sed -i -e '/^[ \t]*#/d' ${sample_id}.emapper.pfam
    fi
    gzip ${sample_id}.emapper*
    sleep 2
    """

}


process checkm2 {
    publishDir "${params.outdir}/${sample_id}/checkm2/", mode: "copy"

    input:
    tuple val(sample_id), path('bins/*')

    output:
    file("${sample_id}.checkm2.tsv")

    script:
    """
    cp -Lr bins uncompressed_bins
    gunzip uncompressed_bins/*
    checkm2 predict -i uncompressed_bins -o out -x .fa
    mv out/quality_report.tsv ${sample_id}.checkm2.tsv
    """
}

process rgiv6 {
    publishDir "${params.outdir}/${sample_id}/rgiv6/", mode: "copy"

    input:
    tuple val(sample_id), file('genecalls/*')

    output:
    file("${sample_id}/*")

    script:
    """
    export MPLCONFIGDIR=./
    mkdir ${sample_id}
    for genecall in genecalls/*.faa
    do
      bin_id=\${genecall:10:\${#genecall}-24}
      rgi main -n 24 -i \${genecall} -o ${sample_id}/\${bin_id}.rgi -t protein -a DIAMOND --clean
    done
    gzip ${sample_id}/*
    sleep 2
    """
}

process gtdbtk {
    publishDir "${params.outdir}/${sample_id}/gtdbtk/", mode: "copy"

    input:
    tuple val(sample_id), file('bins/*')

    output:
    path("${sample_id}", maxDepth: '2')

    script:
    """
    mkdir ${sample_id}
    gtdbtk classify_wf --cpus 24 --pplacer_cpus 24 --genome_dir ./bins --out_dir ${sample_id} --extension .fa.gz
    """
}

workflow {

    print "PARAMS: ${params}"

    // if (params.NCBI_API_KEY == 'none') {
    // input_samples = Channel
    //     .fromSRA(params.input_SRA_id)
    //     .view()
    // }
    // else {
    // input_samples = Channel
    //     .fromSRA(params.input_SRA_id, apiKey:params.NCBI_API_KEY)
    //     .view()
    // }

    // preprocess_fastqs(input_samples)
    // assembly(preprocess_fastqs.out.filtered)
    // gene_calling_prodigal(assembly.out)
    // remove_small_contigs(assembly.out)
    // index(remove_small_contigs.out)
    // alignment(remove_small_contigs.out.join(index.out).join(preprocess_fastqs.out.filtered))
    // depths(alignment.out)

    contigs_ch = Channel.fromPath(params.assembly_input + "/**.${params.suffix_pattern}")
        .map { file -> return tuple(file.getParent().getName(), file) }

    contigs_ch.dump(pretty: true, tag: "contigs_ch")
    
    depth_ch = Channel.fromPath(params.depth_input + "/**.tsv")
        .map { file -> return tuple(file.getParent().getName(), file) }

    depth_ch.dump(pretty: true, tag: "depth_ch")

    gene_calling_prodigal(contigs_ch)

    // binning(depths.out.join(remove_small_contigs.out))
    binning(depth_ch.join(contigs_ch, by: 0))

    calls = binning.out.join(gene_calling_prodigal.out.genecalls_faa).join(gene_calling_prodigal.out.genecalls_fna)
        .flatMap { sample_id, bins, proteins, genes -> 
            bins.collect {
                bin -> tuple(sample_id, bin, proteins, genes)
            }
        }

    per_bin_genecalling(calls)

    bincalls = per_bin_genecalling.out.bincalls
        .groupTuple(by: 0)

    assembly_stats(contigs_ch)
    assembly_mash_sketching(contigs_ch)
    bin_mash_sketching(binning.out)
    rrna_detection(contigs_ch)
    abricate(gene_calling_prodigal.out.genecalls_fna)
    macrel(contigs_ch)
    gunc(binning.out)
    checkm2(binning.out)
    eggnog_mapper(gene_calling_prodigal.out.genecalls_faa)
    rgiv6(per_bin_genecalling.out.bincalls)
    gtdbtk(binning.out)
}
